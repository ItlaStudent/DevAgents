const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
function load(name, imports = {}) {
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8'))(mod, mod.exports, n => imports[n] ?? {});
  return mod.exports;
}
const notices = [];
const { MissionControlPanel } = load('mission_control_ux', {
  '../design/html': load('html_ux'),
  './order_graph': load('order_graph_ux', { '../bridge/core_api': { eventPayload: (e) => e.payload ?? {} }, '../design/html': load('html_ux') }),
  '../design/notice': { notice: m => notices.push(m) },
  '../design/alerts': { raiseAlert: () => {}, clearAlert: () => {}, clearAlertsExcept: () => {} },
  '../design/icons': { icons: new Proxy({}, { get: () => () => '' }) },
  '../design/orbit_backdrop': { orbitBackdrop: () => '' },
  '../layout/layout': { updatePermissionBadge: () => {} },
});
const memory = new Map();
global.window = { localStorage: { getItem: k => memory.get(k) ?? null, setItem: (k, v) => memory.set(k, v) }, setTimeout: fn => fn() };
const host = { innerHTML: '', querySelectorAll: () => [] };
const p = Object.create(MissionControlPanel.prototype);
Object.assign(p, { modelQuery: '', modelRows: [
  { provider: 'Cohere', model: 'command', fav: false, ctx: 0, free: true, available: true },
  { provider: 'Google', model: 'gemma', fav: true, ctx: 0, free: true, available: true },
], pinnedRoles: { plan: '', exec: '', audit: '' }, swarmSelection: [] });
p.container = { querySelector: s => s === '#model-list' ? host : null, querySelectorAll: () => [] };
p.renderSwarmList = () => {};
p.renderModelList();
assert.match(host.innerHTML, /<details[^>]*data-group="provider:Cohere"(?![^>]*\bopen)[^>]*>/);
assert.match(host.innerHTML, /<details[^>]*data-group="favorites"[^>]*\bopen/);
console.log('PASS proveedor cerrado y Favoritos abierto por defecto');
p.bindShell = () => {};
p.renderBody = () => {};
p.render();
assert.match(p.container.innerHTML, /id="model-advanced"/);
assert.ok(p.container.innerHTML.indexOf('id="model-detail-pins"') < p.container.innerHTML.indexOf('id="model-advanced"'));
console.log('PASS resumen básico y opciones avanzadas separadas');
const shellMarkup = p.container.innerHTML;
assert.match(shellMarkup, /id="model-picker" role="group" aria-labelledby="model-picker-title"/);
assert.match(shellMarkup, /id="model-picker-title">/);
assert.match(shellMarkup, /id="model-search"[^>]*aria-label="Buscar modelos"/);
assert.match(shellMarkup, /id="model-groups-toggle"[^>]*aria-controls="model-list"/);
assert.match(shellMarkup, /<summary aria-expanded="true" aria-controls="model-advanced-body">/);
assert.match(shellMarkup, /id="model-advanced-body"/);
// -- modos (006a) --
// Devuelve el marcado completo del elemento cuyo id aparece en el HTML,
// contando anidamientos del mismo tag para encontrar su cierre real.
function outerMarkup(markup, id) {
  const idAt = markup.indexOf(`id="${id}"`);
  assert.ok(idAt >= 0, `falta #${id}`);
  const openAt = markup.lastIndexOf('<', idAt);
  const name = /^<([a-z0-9-]+)/i.exec(markup.slice(openAt))[1];
  const tags = new RegExp(`<${name}\\b|</${name}>`, 'gi');
  tags.lastIndex = openAt;
  let depth = 0, match;
  while ((match = tags.exec(markup))) {
    if (match[0][1] === '/') depth--; else depth++;
    if (depth === 0) return markup.slice(openAt, tags.lastIndex);
  }
  throw new Error(`#${id} sin cierre`);
}
assert.match(shellMarkup, /id="btn-modes-picker"[^>]*aria-controls="modes-picker"/);
assert.match(shellMarkup, /id="modes-picker" role="group" aria-labelledby="modes-picker-title"/);
assert.match(shellMarkup, /id="modes-picker-title">/);
const modesOuter = outerMarkup(shellMarkup, 'modes-picker');
const advancedOuter = outerMarkup(shellMarkup, 'model-advanced');
for (const id of ['wait-plan-approval', 'chk-deterministic', 'num-agentic', 'sel-effort']) {
  assert.ok(modesOuter.includes(`id="${id}"`), `#${id} debe vivir dentro de #modes-picker`);
  assert.ok(!advancedOuter.includes(`id="${id}"`), `#${id} no debe quedar dentro de #model-advanced`);
}
for (const id of ['sel-perm-mode', 'sel-gov-mode', 'sel-best-of-n', 'inp-bon-members']) {
  assert.ok(modesOuter.includes(`id="${id}"`), `#${id} sigue existiendo dentro de Modos`);
}
const directoTag = modesOuter.match(/<button[^>]*data-way="directo"[^>]*>/)?.[0] ?? '';
// Directo ya existe en el motor y se elige como cualquier forma.
assert.ok(directoTag, 'falta el botón Directo');
assert.doesNotMatch(directoTag, /\bdisabled\b/);
assert.doesNotMatch(modesOuter, /Falta en el motor/);
assert.match(advancedOuter, /id="model-advanced-body"/);
assert.match(advancedOuter, /id="chk-swarm-enabled"/);
console.log('PASS compositor con Modos/Modelo, ajustes movidos y Directo elegible');
for (const id of ['btn-modes-picker', 'btn-model-picker']) {
  const tag = shellMarkup.match(new RegExp(`<button[^>]*id="${id}"[^>]*>`))?.[0] ?? '';
  assert.ok(tag, `falta #${id}`);
  assert.doesNotMatch(tag, /class="[^"]*\bselect\b/, `#${id} no debe usar .select`);
  assert.match(tag, /class="[^"]*\bcomposer-pick\b/, `#${id} debe usar .composer-pick`);
}
const chipsHost = { innerHTML: '' };
const modeControls = {
  '#composer-mode-chips': chipsHost,
  '#chk-swarm-enabled': { checked: false },
  '#wait-plan-approval': { checked: false },
  '#sel-perm-mode': { value: 'normal' },
  '#sel-best-of-n': { value: '0' },
  '#num-agentic': { value: '1' },
  '#sel-effort': { value: '' },
};
const chipPanel = Object.create(MissionControlPanel.prototype);
chipPanel.container = { querySelector: s => modeControls[s] ?? null };
chipPanel.renderModeChips();
assert.match(chipsHost.innerHTML, /Orquestado/, 'la forma de trabajar por defecto debe verse siempre');
assert.doesNotMatch(chipsHost.innerHTML, /data-reset="way"/, 'el chip por defecto no lleva ×');
modeControls['#chk-swarm-enabled'].checked = true;
chipPanel.renderModeChips();
assert.match(chipsHost.innerHTML, /Colmena/);
assert.match(chipsHost.innerHTML, /data-reset="way"/, 'Colmena sí lleva ×');
assert.doesNotMatch(chipsHost.innerHTML, /Orquestado/, 'con Colmena activa no se pinta Orquestado');
chipPanel.directMode = true;
chipPanel.renderModeChips();
assert.match(chipsHost.innerHTML, /Directo/, 'en Directo el chip dice Directo');
assert.doesNotMatch(chipsHost.innerHTML, /Colmena|Orquestado/, 'Directo sustituye a las otras formas');
assert.doesNotMatch(chipsHost.innerHTML, /data-reset="way"/, 'Directo es una forma fija, sin ×');
chipPanel.directMode = false;
console.log('PASS botones Modos/Modelo con una flecha (sin .select) y chip Orquestado fijo sin ×');

// USUARIO-NUEVO B (10-nov): «DevAgents», cuarta forma de trabajar, con icono
// propio y una línea de descripción; se recuerda con la misma clave.
{
  const ways = [...modesOuter.matchAll(/data-way="([a-z]+)"/g)].map((m) => m[1]);
  assert.deepEqual(ways, ['directo', 'devagents', 'orquestado', 'colmena'], 'cuatro formas de trabajar, DevAgents tras Directo');
  const devTag = modesOuter.match(/<button[^>]*data-way="devagents"[\s\S]*?<\/button>/)?.[0] ?? '';
  assert.doesNotMatch(devTag.match(/<button[^>]*>/)[0], /\bdisabled\b/);
  assert.match(devTag, /<b[^>]*>[\s\S]*DevAgents<\/b>/);
  assert.match(devTag, /<small>[^<]*delega subtareas en paralelo[^<]*worktree[^<]*<\/small>/);
  // Icono propio: se carga el panel con un catálogo de iconos que se nombra a sí mismo.
  const named = load('mission_control_ux', {
    '../design/html': load('html_ux'),
    './order_graph': load('order_graph_ux', { '../bridge/core_api': { eventPayload: (e) => e.payload ?? {} }, '../design/html': load('html_ux') }),
    '../design/notice': { notice: () => {} },
    '../design/alerts': { raiseAlert: () => {}, clearAlert: () => {}, clearAlertsExcept: () => {} },
    '../design/icons': { icons: new Proxy({}, { get: (_, k) => () => `<i data-icon="${String(k)}"></i>` }) },
    '../design/orbit_backdrop': { orbitBackdrop: () => '' },
  }).MissionControlPanel;
  const np = Object.create(named.prototype);
  Object.assign(np, { modelQuery: '', modelRows: [], pinnedRoles: { plan: '', exec: '', audit: '' }, swarmSelection: [] });
  np.container = { querySelector: () => null, querySelectorAll: () => [] };
  np.renderSwarmList = () => {};
  np.bindShell = () => {};
  np.renderBody = () => {};
  np.render();
  const namedTag = outerMarkup(np.container.innerHTML, 'modes-picker').match(/<button[^>]*data-way="devagents"[\s\S]*?<\/button>/)?.[0] ?? '';
  assert.match(namedTag, /data-icon="delegate"/, 'DevAgents lleva su icono propio');
  assert.equal((np.container.innerHTML.match(/data-icon="delegate"/g) ?? []).length, 1, 'el icono de DevAgents no se recicla en otro sitio');

  chipPanel.directMode = true;
  chipPanel.delegateMode = true;
  chipPanel.renderModeChips();
  assert.match(chipsHost.innerHTML, /DevAgents/, 'en DevAgents el chip dice DevAgents');
  assert.doesNotMatch(chipsHost.innerHTML, /Directo|Colmena|Orquestado/);
  chipPanel.directMode = false;
  chipPanel.delegateMode = false;

  // Elegirlo lo lleva al motor (Directo + delegar) y lo recuerda; volver a
  // Directo apaga la delegación.
  const saved = new Map();
  const prevStorage = global.localStorage;
  global.localStorage = { getItem: (k) => saved.get(k) ?? null, setItem: (k, v) => saved.set(k, v), removeItem: (k) => saved.delete(k) };
  const calls = [];
  const handlers = {};
  const button = (way) => ({ dataset: { way }, disabled: false, addEventListener: (_, fn) => { handlers[way] = fn; } });
  const root = { querySelectorAll: () => [button('directo'), button('devagents')] };
  const wp = Object.create(MissionControlPanel.prototype);
  Object.assign(wp, {
    directMode: false, delegateMode: false, phase: 'running',
    core: { setDirect: (enabled, delegate) => { calls.push([enabled, delegate]); return Promise.resolve({ enabled, delegate }); } },
    container: { querySelector: (s) => (s === '#modes-picker' ? root : null) },
    updateModelChip: () => {}, syncComposerPlaceholder: () => {}, syncModesPanel: () => {},
  });
  wp.bindModeWays();
  handlers.devagents();
  assert.deepEqual(calls.at(-1), [true, true], 'DevAgents = Directo que delega');
  assert.equal(saved.get('devagents.workmode.v1'), 'devagents', 'se recuerda con WORK_MODE_KEY');
  assert.equal(wp.directMode && wp.delegateMode, true);
  handlers.directo();
  assert.deepEqual(calls.at(-1), [true, false], 'Directo no delega');
  assert.equal(saved.get('devagents.workmode.v1'), 'directo');
  global.localStorage = prevStorage;
  console.log('PASS DevAgents: cuarta forma con icono propio, chip, motor y recuerdo');
}

// (9-nov): una IDE normal recuerda el modelo elegido al reabrir.
const recuerdoModelo = (async () => {
  const saved = new Map();
  global.localStorage = { getItem: k => saved.get(k) ?? null, setItem: (k, v) => saved.set(k, v), removeItem: k => saved.delete(k) };
  const calls = [];
  const fakeCore = (plan = { provider: '', model: '' }) => ({
    getPlanModel: async () => plan,
    getExecModel: async () => ({ provider: '', model: '' }),
    setPlanModel: async (pr, m) => { calls.push(['plan', pr, m]); return { applied: true }; },
    setExecModel: async (pr, m) => { calls.push(['exec', pr, m]); return { applied: true }; },
  });
  const mk = core => Object.assign(Object.create(MissionControlPanel.prototype), { core, pinnedRoles: { plan: '', exec: '', audit: '' }, explicitRoleRows: new Set(), orderModelRestored: false });
  // Elegir guarda; elegir Automático olvida.
  await mk(fakeCore()).applyOrderModelChoice('Cohere', 'command-a');
  assert.equal(saved.get('devagents.orderModel.v1'), 'Cohere|command-a');
  // Al reabrir con el motor en Automático, se reaplica una sola vez.
  calls.length = 0;
  const reopened = mk(fakeCore());
  await reopened.restoreSavedOrderModel();
  await reopened.restoreSavedOrderModel();
  assert.deepEqual(calls, [['plan', 'Cohere', 'command-a']]);
  // Si el motor ya tiene otro fijado, no se pisa.
  calls.length = 0;
  await mk(fakeCore({ provider: 'Google', model: 'gemma' })).restoreSavedOrderModel();
  assert.deepEqual(calls, []);
  // Si el motor lo rechaza, se olvida y queda Automático.
  const refusing = mk({ ...fakeCore(), setPlanModel: async () => { throw new Error('E_MODEL_UNKNOWN'); } });
  await refusing.restoreSavedOrderModel();
  assert.equal(saved.has('devagents.orderModel.v1'), false);
  await mk(fakeCore()).applyOrderModelChoice('Cohere', 'command-a');
  await mk(fakeCore()).applyOrderModelChoice('', '');
  assert.equal(saved.has('devagents.orderModel.v1'), false);
  delete global.localStorage;
  console.log('PASS el modelo elegido se recuerda al reabrir (y se olvida si el motor ya no lo admite)');
})().catch(e => { console.error(e); process.exit(1); });

// T2d-D2 (12-nov): en Directo, elegir Codex tras OpenCode (con la cabina
// recargada en medio, como en la matriz F0.6) quita el ejecutor viejo; en
// Orquestado un ejecutor explícito se respeta. Va después del bloque anterior:
// los dos escriben el modelo recordado en el mismo localStorage simulado.
recuerdoModelo.then(async () => {
  const calls = [];
  const core = {
    setPlanModel: async (pr, m) => { calls.push(['plan', pr, m]); return { applied: true }; },
    setExecModel: async (pr, m) => { calls.push(['exec', pr, m]); return { applied: true }; },
  };
  // Tras recargar, renderRoleRows marca el ejecutor OpenCode como fila explícita.
  const reloaded = direct => Object.assign(Object.create(MissionControlPanel.prototype), {
    core, directMode: direct, mainCliChoice: '',
    pinnedRoles: { plan: '', exec: 'agent:opencode|opencode/deepseek-v4.1-flash-free', audit: '' },
    explicitRoleRows: new Set(['exec']),
  });
  await reloaded(true).applyOrderModelChoice('agent:codex', 'default');
  assert.deepEqual(calls, [['plan', 'agent:codex', 'default'], ['exec', '', '']]);
  calls.length = 0;
  await reloaded(false).applyOrderModelChoice('agent:codex', 'default');
  assert.deepEqual(calls, [['plan', 'agent:codex', 'default']]);
  console.log('PASS Directo: la última elección del selector es la que corre (el ejecutor viejo se limpia)');
}).catch(e => { console.error(e); process.exit(1); });

// -- modelo (006b) --
const modelAdvanced = outerMarkup(shellMarkup, 'model-advanced');
assert.match(modelAdvanced, /^<details[^>]*\bopen\b/, '#model-advanced debe estar abierto por defecto');
assert.match(modelAdvanced, /<summary aria-expanded="true" aria-controls="model-advanced-body">/);
assert.ok(modelAdvanced.includes('id="chk-swarm-enabled"'), 'la Colmena conserva el interruptor del enjambre');
assert.ok(modelAdvanced.includes('id="swarm-list"'), 'la Colmena conserva la lista del enjambre');
assert.ok(!modelAdvanced.includes('id="btn-vision-probe"'), 'Visión no debe vivir dentro de la Colmena');
assert.ok(!modelAdvanced.includes('id="external-model-detail"'), 'El agente externo no debe vivir dentro de la Colmena');
const modelVision = outerMarkup(shellMarkup, 'model-vision-group');
assert.ok(modelVision.includes('id="btn-vision-probe"'), '#btn-vision-probe debe vivir en #model-vision-group');
assert.ok(modelVision.includes('id="vision-probe-status"'), '#vision-probe-status debe vivir en #model-vision-group');
const modelExternal = outerMarkup(shellMarkup, 'model-external-group');
assert.ok(modelExternal.includes('id="external-model-detail"'), '#external-model-detail debe vivir en #model-external-group');
assert.match(modelExternal, /^<details[^>]*\bhidden\b[^>]*>/, '#model-external-group arranca oculto');
assert.match(shellMarkup, /<label class="model-role-grid__main" for="sel-model">Modelo de la orden<\/label>/);
const roleRowsHost = { innerHTML: '' };
const addRole = { disabled: false };
const rolePanel = Object.create(MissionControlPanel.prototype);
Object.assign(rolePanel, { explicitRoleRows: new Set(['audit']), pinnedRoles: { plan: '', exec: '', audit: '' }, extraRolePins: {}, mainCliChoice: '' });
rolePanel.container = { querySelector: s => s === '#model-role-rows' ? roleRowsHost : s === '#btn-add-role' ? addRole : null };
rolePanel.renderRoleRows();
assert.match(roleRowsHost.innerHTML, /class="model-role-hint">Revisa; nunca del mismo fabricante que quien produjo\.</);
assert.equal(addRole.disabled, false, '«+ rol» sigue disponible con menos de 5 roles');
// P2-b (2) y (3): los cinco roles pintan su pista y «+ rol» se bloquea al llegar a 5.
rolePanel.explicitRoleRows = new Set(['exec', 'audit', 'second_audit', 'programmer', 'sidekick']);
rolePanel.renderRoleRows();
for (const hint of ['Ejecuta las tareas productoras.', 'Revisa; nunca del mismo fabricante que quien produjo.',
  'Alterna con el auditor; si falta, el motor clona una auditoría.', 'Tareas programar, programar_c, _cpp y _zig.',
  'Tareas investigar, resumir y documentar.']) {
  assert.ok(roleRowsHost.innerHTML.includes(hint), `falta la pista de rol: ${hint}`);
}
assert.equal(addRole.disabled, true, '«+ rol» debe deshabilitarse con 5 roles');
console.log('PASS modelo: colmena abierta, visión y agente externo en sus grupos, etiqueta, cinco pistas y tope de 5 roles');

// -- comportamiento del segmentado y de los × (006a) --
function segButton(value) {
  const classes = new Set();
  return { dataset: { value }, disabled: false, classes, attrs: {},
    classList: { toggle(name, on) { if (on) classes.add(name); else classes.delete(name); } },
    setAttribute(name, value) { this.attrs[name] = value; },
    closest() { return this; } };
}
function segGroup(buttons) {
  return { listeners: {}, addEventListener(name, fn) { this.listeners[name] = fn; },
    querySelectorAll: () => buttons };
}
function segSelect(value) {
  return { value, listeners: {}, events: [], addEventListener(name, fn) { this.listeners[name] = fn; },
    dispatchEvent(event) { this.events.push(event); return true; } };
}
const segButtons = [segButton('normal'), segButton('bypass')];
const segSel = segSelect('normal');
const segPanel = Object.create(MissionControlPanel.prototype);
const segControls = { '#sel-perm-mode': segSel, '[data-segmented="sel-perm-mode"]': segGroup(segButtons) };
segPanel.container = { querySelector: s => segControls[s] ?? null };
segPanel.bindSegmented('sel-perm-mode');
segControls['[data-segmented="sel-perm-mode"]'].listeners.click({ target: segButtons[1] });
assert.equal(segSel.value, 'bypass');
assert.equal(segSel.events.filter(e => e.type === 'change').length, 1);
assert.ok(segButtons[1].classes.has('is-active'));
assert.equal(segButtons[1].attrs['aria-pressed'], 'true');
assert.ok(!segButtons[0].classes.has('is-active'));
console.log('PASS segmentado escribe el select, despacha un change y marca el botón');

const resetSel = segSelect('bypass');
const resetPanel = Object.create(MissionControlPanel.prototype);
const resetControls = {
  '#sel-perm-mode': resetSel,
  '[data-segmented="sel-perm-mode"]': null,
  '#chk-swarm-enabled': { checked: false },
  '#wait-plan-approval': { checked: false },
  '#sel-best-of-n': { value: '0' },
  '#num-agentic': { value: '1' },
  '#sel-effort': { value: '' },
  '#composer-mode-chips': { innerHTML: '' },
};
resetPanel.container = { querySelector: s => resetControls[s] ?? null };
resetPanel.resetMode('perm');
assert.equal(resetSel.value, 'normal');
assert.equal(resetSel.events.filter(e => e.type === 'change').length, 1);
assert.match(resetControls['#composer-mode-chips'].innerHTML, /Orquestado/);
console.log('PASS × de permisos vuelve a normal y despacha change');
for (const match of host.innerHTML.matchAll(/<summary(?: tabindex="-1")? aria-expanded="(true|false)" aria-controls="([^"]+)">/g)) {
  assert.ok(host.innerHTML.includes(`id="${match[2]}"`));
}
assert.equal((host.innerHTML.match(/aria-controls="model-group-options-/g) || []).length, 2);
const key = 'devagents.cabin.disclosure.v1';
p.writeCabinDisclosure({ 'provider:Cohere': true, advanced: true, favorites: false });
p.renderModelList();
assert.match(host.innerHTML, /data-group="provider:Cohere"[^>]*open/);
assert.match(host.innerHTML, /data-group="favorites"(?![^>]*\bopen)[^>]*>/);
const saved = memory.get(key);
p.modelQuery = 'gemma'; p.renderModelList();
assert.match(host.innerHTML, /data-group="favorites"[^>]*open/);
assert.equal(memory.get(key), saved);
p.modelQuery = ''; p.renderModelList();
assert.match(host.innerHTML, /data-group="favorites"(?![^>]*\bopen)[^>]*>/);
console.log('PASS preferencia persiste y búsqueda temporal no la cambia');
memory.set('devagents.recentModels', '["Google|gemma"]'); p.renderModelList();
assert.match(host.innerHTML, /data-group="favorites"/);
assert.equal((host.innerHTML.match(/data-val="Google\|gemma"/g) || []).length, 1);
console.log('PASS favorito reciente permanece en Favoritos sin duplicar');
p.modelRows.push({ provider: '<img>', model: '<script>', available: true, ctx: 0 });
p.renderModelList(); assert.ok(!host.innerHTML.includes('<script>')); assert.ok(host.innerHTML.includes('&lt;script&gt;'));
console.log('PASS etiquetas externas escapadas');

const { externalModelRows } = require('../dist/external_models.test.cjs');
p.modelRows = externalModelRows([{provider:'agent:opencode',cli:'opencode',display:'OpenCode',exe:'C:/app/opencode.exe',
  version:'1.18.25',session:'api_key',enumeration_status:'enumerated',models:[
    {slug:'opencode/x-free',display_name:'opencode/x-free',manufacturer:'unknown',reasoning_efforts:[],free:true,label:'OpenCode · opencode/x-free (gratis)'},
    {slug:'opencode/claude-opus-5',display_name:'opencode/claude-opus-5',manufacturer:'anthropic',reasoning_efforts:[],free:false},
  ]}]);
p.renderModelList();
const freeButton = host.innerHTML.match(/<button[^>]*data-val="agent:opencode\|opencode\/x-free"[\s\S]*?<\/button>/)?.[0];
assert.ok(freeButton,'CK-CAB-002 opencode free selector renders the model');
assert.match(freeButton,/Gratis/);
assert.doesNotMatch(freeButton,/API bloqueada|caído|disabled/);
assert.match(host.innerHTML,/API bloqueada/);
assert.doesNotMatch(host.innerHTML,/caído/,'CLI authentication is not a health probe');
const swarmHost = { innerHTML: '' };
p.container.querySelector = s => s === '#swarm-list' ? swarmHost : s === '#model-list' ? host : null;
delete p.renderSwarmList;
p.swarmExtras = []; p.swarmBlocked = []; p.swarmAuto = false;
p.renderSwarmList();
const freeSwarm = swarmHost.innerHTML.match(/<label[^>]*>[\s\S]*?value="agent:opencode\|opencode\/x-free"[\s\S]*?<\/label>/)?.[0];
assert.match(freeSwarm,/Gratis/);
assert.doesNotMatch(freeSwarm,/API bloqueada|caído|disabled/);
assert.match(swarmHost.innerHTML,/value="agent:opencode\|opencode\/claude-opus-5"\s+disabled/);
assert.doesNotMatch(swarmHost.innerHTML,/caído/);
p.renderSwarmList = () => {};
p.container.querySelector = s => s === '#model-list' ? host : null;
console.log('PASS CK-CAB-002 opencode free selector and swarm show Gratis without false health failures');
for (const invalid of ['{', '[]', '{"advanced":"true"}', '{"__proto__":true}']) {
  const count = notices.length;
  memory.set(key, invalid); assert.deepEqual(p.readCabinDisclosure(), {});
  assert.equal(notices.length, count + 1);
  assert.match(notices.at(-1), /leer las preferencias/);
}
const storage = window.localStorage;
window.localStorage = { getItem() { throw Error('denegado'); }, setItem() { throw Error('sin espacio'); } };
assert.deepEqual(p.readCabinDisclosure(), {}); p.writeCabinDisclosure({ advanced: true });
assert.match(notices.at(-1), /guardar las preferencias/); window.localStorage = storage; memory.delete(key);
console.log('PASS JSON corrupto y almacenamiento denegado tienen aviso');

function element(tag = 'BUTTON') {
  return { tagName: tag, value: '', dataset: {}, style: {}, attrs: {}, listeners: {}, isConnected: true,
    addEventListener(n, fn) { this.listeners[n] = fn; }, setAttribute(k, v) { this.attrs[k] = v; },
    focus() { this.focused = true; }, scrollIntoView() {}, matches() { return true; },
    closest() { return this.group ?? null; }, querySelector() { return null; }, contains() { return false; } };
}
// P2-a (4): la Colmena se pliega con su propia clave `colmena`; la clave
// legada `advanced` (de cuando #model-advanced era «Opciones avanzadas») no
// debe cerrarla. Sin clave guardada, arranca abierta.
function colmenaOpen(stored) {
  const colmena = element('DETAILS'), colmenaSummary = element('SUMMARY');
  colmena.open = true; colmena.querySelector = () => colmenaSummary;
  const panel = Object.create(MissionControlPanel.prototype);
  const shell = element('DIV');
  shell.querySelector = s => s === '#model-advanced' ? colmena : null;
  shell.querySelectorAll = () => [];
  Object.assign(panel, { container: shell, core: null, modelQuery: '', modelRows: [], hooks: {} });
  panel.renderModelList = () => {}; panel.renderBody = () => {};
  if (stored === undefined) memory.delete(key); else memory.set(key, JSON.stringify(stored));
  panel.bindShell();
  return colmena.open;
}
assert.equal(colmenaOpen({ advanced: false }), true, 'la clave legada advanced no debe cerrar la Colmena');
assert.equal(colmenaOpen({ colmena: false }), false, 'la clave colmena debe cerrar la Colmena');
assert.equal(colmenaOpen(undefined), true, 'sin clave guardada la Colmena arranca abierta');
console.log('PASS P2-a: Colmena abierta con advanced legado, cerrada con colmena y abierta por defecto');
// El recorrido de foco se verifica en Chromium con el DOM/CSS de producto.
const group = element('DETAILS');
group.open = false; group.dataset.group = 'provider:Cohere';

const advanced = element('DETAILS'), advancedSummary = element('SUMMARY'), toggle = element(), picker = element(), chip = element();
advanced.querySelector = () => advancedSummary;
const search = element('INPUT');
search.contains = node => node === search;
const docListeners = {};
global.document = { addEventListener: (name, fn) => { docListeners[name] = fn; }, removeEventListener: name => { delete docListeners[name]; } };
const bound = Object.create(MissionControlPanel.prototype);
const elements = { '#model-advanced': advanced, '#model-groups-toggle': toggle, '#model-picker': picker, '#btn-model-picker': chip, '#model-search': search };
const container = element('DIV'); container.querySelector = s => elements[s] ?? null; container.querySelectorAll = () => [group];
Object.assign(bound, { container, core: null, modelQuery: '', modelRows: [1], modelPickerOpen: false, hooks: {} });
bound.renderModelList = () => {}; bound.renderBody = () => {};
bound.bindShell(); assert.equal(advanced.open, false); assert.equal(advancedSummary.attrs['aria-expanded'], 'false');
advanced.open = true; advanced.listeners.toggle(); assert.equal(JSON.parse(memory.get(key)).colmena, true);
advanced.open = false; bound.bindShell(); assert.equal(advanced.open, true);
group.open = false; toggle.listeners.click(); assert.equal(group.open, true);
assert.equal(JSON.parse(memory.get(key))['provider:Cohere'], true);
assert.equal(toggle.textContent, 'Colapsar todo');
toggle.listeners.click(); assert.equal(group.open, false); assert.equal(toggle.textContent, 'Expandir todo');
bound.modelQuery = 'gemma'; const beforeSearch = memory.get(key); toggle.listeners.click(); assert.equal(memory.get(key), beforeSearch);
// el cierre por Escape y clic fuera escucha en `document` solo
// mientras el selector está abierto; Escape en el buscador limpia antes.
bound.modelQuery = ''; chip.focused = false;
bound.setModelPickerOpen(true, false);
assert.equal(bound.modelPickerOpen, true); assert.equal(chip.attrs['aria-expanded'], 'true');
assert.equal(typeof docListeners.keydown, 'function'); assert.equal(typeof docListeners.mousedown, 'function');
bound.modelQuery = 'gemma'; search.value = 'gemma';
docListeners.keydown({ key: 'Escape', target: search, preventDefault() {}, stopPropagation() {} });
assert.equal(bound.modelQuery, ''); assert.equal(search.value, ''); assert.equal(bound.modelPickerOpen, true);
docListeners.keydown({ key: 'Escape', target: search, preventDefault() {}, stopPropagation() {} });
assert.equal(bound.modelPickerOpen, false); assert.equal(chip.focused, true); assert.equal(chip.attrs['aria-expanded'], 'false');
assert.equal(docListeners.keydown, undefined); assert.equal(docListeners.mousedown, undefined);
chip.focused = false; bound.setModelPickerOpen(true, false);
docListeners.mousedown({ target: {} });
assert.equal(bound.modelPickerOpen, false); assert.equal(chip.focused, false);
console.log('PASS bindings expandir/colapsar, avanzado recordado y Escape devuelve foco');

const pins = element('DIV'), warning = element('DIV');
p.container.querySelector = s => s === '#model-detail-pins' ? pins : s === '#model-audit-warning' ? warning : null;
p.pinnedRoles = { plan: 'Cohere|command', exec: '', audit: '' }; p.renderPinSummary();
assert.equal(pins.textContent, 'command · ejecuta igual · auditor automático'); assert.match(warning.textContent, /Revisión por decidir/);
p.modelRows.push({ provider: 'agent:codex', model: 'sol', manufacturer: 'OpenAI' }, { provider: 'agent:other', model: 'sol2', manufacturer: 'openai' });
p.pinnedRoles.exec = 'agent:codex|sol'; p.pinnedRoles.audit = 'agent:other|sol2'; p.renderPinSummary(); assert.match(warning.textContent, /Revisión por decidir/);
p.modelRows.at(-1).manufacturer = 'otro'; p.renderPinSummary(); assert.match(warning.textContent, /Revisión por decidir/);
p.modelRows.at(-1).manufacturer = undefined; p.renderPinSummary(); assert.match(warning.textContent, /Revisión por decidir/);
console.log('PASS resumen de pines y aviso neutro hasta asignación efectiva del motor');

const { themes } = load('theme_registry_ux', { './tokens': load('tokens_ux') });
function luminance(color) {
  const rgb = color.match(/^#([a-f0-9]{6})$/i); assert.ok(rgb, color);
  const channels = [0, 2, 4].map(i => parseInt(rgb[1].slice(i, i + 2), 16) / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4);
  return channels[0] * .2126 + channels[1] * .7152 + channels[2] * .0722;
}
for (const theme of Object.values(themes).filter(t => t.base === 'dark')) {
  for (const background of ['bgApp','bgTitlebar','bgActivityBar','bgSidebar','bgMain','bgPanel','bgStatusBar','surface1','surface2','surface3']) {
    const a = luminance(theme.colors.fgSubtle), b = luminance(theme.colors[background]);
    const ratio = (Math.max(a, b) + .05) / (Math.min(a, b) + .05);
    assert.ok(ratio >= 4.5, `${theme.id}/${background} ${ratio.toFixed(2)}`);
    console.log(`CONTRAST ${theme.id}/${background} ${ratio.toFixed(2)}`);
  }
}
let css;
global.document = { createElement: () => ({}), head: { appendChild: el => { css = el.textContent; } } };
load('stylesheet_ux', { './tokens': load('tokens_ux') }).injectStylesheet();
assert.match(css, /\.input:focus-visible, \.select:focus-visible, \.textarea:focus-visible\s*\{\s*outline: 2px solid/);
assert.match(css, /\.model-role-actions[^}]*flex-wrap: wrap/);
console.log('PASS foco visible y botones adaptables presentes en CSS de producto');
// Remate D1 (10-nov): una sesión que delegó y no integró todo no sale «Hecha» a secas.
{
  const sl = load('status_labels_ux');
  assert.equal(sl.estadoDeSesion('audit_unavailable', 2, 0), 'Sin auditar · 0 de 2 integradas');
  assert.equal(sl.estadoDeSesion('done', 2, 1), 'Hecha · 1 de 2 integradas');
  assert.equal(sl.estadoDeSesion('failed', 2, 0), 'Fallida · 0 de 2 integradas');
  assert.equal(sl.estadoDeSesion('done', 2, 2), 'Hecha');
  assert.equal(sl.estadoDeSesion('done', undefined, undefined), 'Hecha');
  assert.equal(sl.delegacionIncompleta(2, 0), true);
  assert.equal(sl.delegacionIncompleta(2, 2), false);
  assert.equal(sl.delegacionIncompleta(0, 0), false);
  console.log('PASS D1: la barra lateral dice cuántas subtareas delegadas se integraron');
}
(async () => {
  const cli = element('DIV'), detail = element('DETAILS'), detailSummary = element('SUMMARY');
  detail.open = false; detail.querySelector = () => detailSummary;
  const externalGroup = element('DETAILS'), externalSummary = element('SUMMARY');
  externalGroup.hidden = true; externalGroup.querySelector = () => externalSummary;
  const execButton = element(), auditButton = element(), effort = element('SELECT'), cliPath = element('INPUT'), pathSave = element();
  const controls = { '.external-cli-detail': detail, '#external-pin-exec': execButton, '#external-pin-audit': auditButton,
    '#external-reasoning': effort, '#external-path': cliPath, '#external-path-save': pathSave };
  cli.querySelector = s => controls[s] ?? null;
  const calls = [];
  const row = { provider: 'agent:codex', model: 'sol', group: 'Codex', label: 'Sol <img>', available: true, agent: true,
    version: '0.159.2', session: 'suscripcion', signature: 'trusted', exe: 'C:/synthetic/codex.exe', reason: '<script>',
    aclSignals: ['synthetic SID'], efforts: ['high'], effort: '', enumeration: 'enumerated' };
  Object.assign(p, { modelRows: [row], externalDetail: 'agent:codex|sol',
    core: { getExternalPaths: async () => ({ codex: 'C:/synthetic/codex.exe' }),
      setExecModel: async (...args) => calls.push(['exec', ...args]),
      setAuditModel: async (...args) => calls.push(['audit', ...args]),
      setExternalModelOptions: async (...args) => calls.push(['effort', ...args]),
      setExternalPaths: async value => calls.push(['path', value]), refreshExternalAgents: async () => {} } });
  p.container.querySelector = s => s === '#external-model-detail' ? cli : s === '#model-external-group' ? externalGroup : null;
  p.refreshModelPickers = async () => {};
  p.renderExternalDetail();
  assert.equal(externalGroup.hidden, false, 'renderExternalDetail debe mostrar #model-external-group al pintar una fila');
  assert.equal(externalSummary.textContent, 'Agente externo · Codex', 'el summary del grupo debe nombrar al agente');
  assert.match(cli.innerHTML, /Codex 0.159.2 · suscripción · firma verificada/);
  assert.match(cli.innerHTML, /<details class="external-cli-detail"><summary aria-expanded="false" aria-controls="external-cli-detail-body">Ver detalle/);
  assert.match(cli.innerHTML, /id="external-cli-detail-body"/);
  assert.ok(!cli.innerHTML.includes('<script>') && !cli.innerHTML.includes('Sol <img>'));
  assert.ok(cli.innerHTML.indexOf('id="external-pin-audit"') < cli.innerHTML.indexOf('<details'));
  detail.open = true; detail.listeners.toggle(); assert.equal(detailSummary.attrs['aria-expanded'], 'true');
  execButton.listeners.click(); auditButton.listeners.click(); effort.value = 'high'; effort.listeners.change({ target: effort });
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls.slice(0, 3), [['exec', 'agent:codex', 'sol'], ['audit', 'agent:codex', 'sol'], ['effort', 'agent:codex', 'sol', 'high']]);
  assert.equal(cliPath.value, 'C:/synthetic/codex.exe');
  cliPath.value = 'C:/synthetic/override.exe'; pathSave.listeners.click(); await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(calls.at(-1), ['path', { codex: 'C:/synthetic/override.exe' }]);
  p.core.setExecModel = async () => { throw Error('rechazo sintético'); };
  execButton.listeners.click(); await new Promise(resolve => setImmediate(resolve)); assert.match(notices.at(-1), /rechazo sintético/);
  p.core.setExternalModelOptions = async () => { throw Error('esfuerzo inválido'); };
  effort.listeners.change({ target: effort }); await new Promise(resolve => setImmediate(resolve)); assert.match(notices.at(-1), /esfuerzo inválido/);
  p.core.getExternalPaths = async () => { throw Error('rutas inaccesibles'); };
  p.renderExternalDetail(); await new Promise(resolve => setImmediate(resolve)); assert.match(notices.at(-1), /rutas inaccesibles/);
  p.externalDetail = 'ausente'; p.pinnedRoles = { plan: '', exec: '', audit: '' }; cli.replaceChildren = () => { cli.innerHTML = ''; };
  p.renderExternalDetail(); assert.equal(cli.innerHTML, '');
  assert.equal(externalGroup.hidden, true, 'sin fila, #model-external-group debe ocultarse');
  assert.equal(externalSummary.textContent, 'Agente externo', 'al vaciarse, el summary vuelve a «Agente externo»');
  console.log('PASS CLI compacta/detalle, cuatro acciones puente, grupo externo visible/oculto y errores explícitos');
  // 8-nov (propietario: sus dos primeros envíos «no funcionaron»): si la conversación
  // cambia mientras el motor comprueba la configuración, la orden no arranca;
  // antes se perdía en silencio, ahora avisa y devuelve false (el compositor
  // recupera el texto).
  {
    const sp = Object.create(MissionControlPanel.prototype);
    Object.assign(sp, { phase: 'idle', orderEpoch: 1, pendingIssue: null, container: { querySelector: () => null },
      showConfiguration() {}, core: { orderPreflight: async () => { sp.orderEpoch += 1; return { allowed: true, issues: [] }; } } });
    const before = notices.length;
    const started = await sp.submit('Hola');
    assert.equal(started, false, 'Un envío que no arranca lo dice (false)');
    assert.equal(notices.length, before + 1, 'y avisa');
    assert.match(notices.at(-1), /No se envió: la conversación cambió/);
    sp.core.orderPreflight = async () => ({ allowed: false, issues: [{ role: 'planificador', provider: 'p', model: 'm', reason: 'sin clave', action: 'Configura la clave' }] });
    assert.equal(await sp.submit('Hola'), false, 'Preflight denegado: tampoco arranca y el texto se conserva');
    console.log('PASS envío: ningún mensaje se pierde en silencio antes de arrancar la orden');
  }
  {
    // cambiar de modo no abre el aviso de la página (la doble
    // confirmación era el `confirmModal` + el diálogo del host); las listas
    // salen del motor, no del espejo; si el host no lo permite, el selector
    // vuelve al modo vigente y se dice en una línea.
    const source = fs.readFileSync(path.join(__dirname, '../src/panes/mission_control.ts'), 'utf8');
    assert.ok(!source.includes('Vas a activar el modo'), 'el compositor ya no pide confirmación propia para Auto/Omitir');
    const settingsSource = fs.readFileSync(path.join(__dirname, '../src/panes/settings_memory.ts'), 'utf8');
    assert.ok(!settingsSource.includes('Vas a activar el modo'), 'Configuración tampoco');
    assert.match(settingsSource, /Volver a pedir confirmación para Auto y Omitir/);
    memory.set('devagents.permissions', JSON.stringify({ mode: 'normal', allow: ['viejo'], deny: [] }));
    const sets = [];
    let refuse = false;
    const permSel = { value: 'bypass' };
    const pp = Object.create(MissionControlPanel.prototype);
    pp.container = { querySelector: s => (s === '#sel-perm-mode' ? permSel : null) };
    pp.syncModesPanel = () => {};
    pp.core = {
      getPermissions: async () => ({ mode: 'accept_edits', allow: [], deny: ['rm'] }),
      setPermissions: async (...args) => {
        sets.push(args);
        if (refuse) throw new Error('E_NATIVE_CONSENT_REQUIRED: Hace falta la autorización nativa del host');
        return { applied: true };
      },
    };
    await pp.applyPermissionMode('bypass');
    assert.deepEqual(sets[0], ['bypass', [], ['rm']], 'listas del motor, no del espejo viejo');
    assert.equal(JSON.parse(memory.get('devagents.permissions')).mode, 'bypass');
    refuse = true;
    notices.length = 0;
    permSel.value = 'autonomous';
    await pp.applyPermissionMode('autonomous');
    assert.equal(permSel.value, 'accept_edits', 'el selector vuelve al modo vigente');
    assert.equal(notices.length, 1);
    assert.match(notices[0], /no cambió: no se permitió en la ventana de DevAgents/);
    console.log('PASS permisos: sin aviso propio, listas del motor y «No permitir» deja el modo vigente');
  }
  {
    // QA-B 2c: selector de cuenta en el compositor, solo para la CLI elegida
    // (Codex o Claude Code) y solo si tiene cuentas.
    const select = { hidden: true, innerHTML: '', value: '', dataset: {}, title: '' };
    const state = { clis: [
      { cli: 'claude-code', display: 'Claude Code', envVar: 'CLAUDE_CONFIG_DIR', selected: 'claude-code-2', accounts: [{ id: 'claude-code-1', label: 'Trabajo' }, { id: 'claude-code-2', label: 'Personal' }] },
      { cli: 'codex', display: 'Codex', envVar: 'CODEX_HOME', selected: null, accounts: [] },
    ], unsupported: [] };
    const mk = (exec, plan = '') => Object.assign(Object.create(MissionControlPanel.prototype), {
      core: { getCliAccounts: async () => state },
      pinnedRoles: { plan, exec, audit: '' },
      container: { querySelector: s => s === '#composer-cli-account' ? select : null },
    });
    await mk('agent:claude-code|sonnet').refreshCliAccountPicker();
    assert.equal(select.hidden, false);
    assert.equal(select.value, 'claude-code-2');
    assert.match(select.innerHTML, /Claude Code: Trabajo/);
    assert.match(select.innerHTML, /login del sistema/);
    assert.equal(select.dataset.cli, 'claude-code');
    await mk('agent:codex|gpt-6-sol').refreshCliAccountPicker();
    assert.equal(select.hidden, true, 'Codex sin cuentas: no se muestra');
    await mk('', 'Google|gemma').refreshCliAccountPicker();
    assert.equal(select.hidden, true, 'modelo por API: no se muestra');
    console.log('PASS QA-B 2c: el compositor ofrece las cuentas de la CLI elegida, solo si tiene');
  }
  await require('./cabina_ux_browser.cjs')();
  await require('./activity_panel.test.cjs')();
  await require('./activity_collapse.test.cjs')();
  await require('./layout_b.test.cjs')();
  await require('./code_copy_file_actions.test.cjs')();
  await require('./contexto_compositor.test.cjs')();
  await require('./attention.test.cjs')();
  await require('./cab031.test.cjs')();
  await require('./keybindings.test.cjs')();
  console.log('UX: pruebas CJS y foco Chromium PASS; 70 contrastes; catálogo sintético, cabina pendiente');
})().catch(error => { console.error(error); process.exitCode = 1; });
