// Synthetic product paths; no browser, credentials or inference.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');
require.extensions['.ts'] = (module, filename) => {
  module._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  }).outputText, filename);
};
const notices = [];
const noticePath = require.resolve('../src/design/notice.ts');
require.cache[noticePath] = { exports: { notice: message => notices.push(message) } };
// 10-nov: los avisos de modelo/presupuesto viven en las alertas de esquina.
const alerts = new Map();
const alertsPath = require.resolve('../src/design/alerts.ts');
require.cache[alertsPath] = { exports: {
  raiseAlert: spec => alerts.set(spec.id, spec),
  clearAlert: id => alerts.delete(id),
  clearAlertsExcept: (prefix, keep) => { for (const id of [...alerts.keys()]) if (id.startsWith(prefix) && !keep.has(id)) alerts.delete(id); },
  activeAlertIds: () => [...alerts.keys()],
} };
const alertText = () => [...alerts.values()].map(a => [a.title, a.body ?? ''].join(' ')).join(' ');
const alertAction = label => [...alerts.values()].flatMap(a => a.actions ?? []).find(x => x.label === label);
const { construirActividad, canalDe } = require('../src/chat_activity.ts');
const { synthProblems, describeProviderFailure } = require('../src/ui_diag.ts');
const { externalModelRows } = require('../src/external_models.ts');
const { MissionControlPanel } = require('../src/panes/mission_control.ts');
const { CoreApi } = require('../src/bridge/core_api.ts');
const failure = { provider:'Cohere', model:'command-a-plus-05-2026', http_status:429, reason:'cuota o limite', excerpt:'[texto externo] trial limit <script>x</script>', error_name:'RateLimited' };
const event = (kind, payload, id=1) => ({ id, ts:1790000000000, source:'fixture', kind, payload });
const events = [event('provider_failed',failure),event('order_failed',{cause:'planner_failed',reason:'Cohere HTTP 429: cuota o limite'},2)];
const activity = construirActividad(events,{ahora:1790000001000,vivo:false});
assert.match(describeProviderFailure(failure), /429/);
assert.match(JSON.stringify(activity), /cuota o limite/);
assert.match(JSON.stringify(synthProblems(events)), /429/);
const panel = Object.create(MissionControlPanel.prototype);
Object.assign(panel,{events,orderId:42,phase:'error',activityOpen:false,activityFilter:'',activityShowAll:false});
const html = panel.renderActivity();
assert(html.includes('429') && html.includes('cuota o limite'));
assert(!html.includes('<script>'), 'external diagnostics must be escaped');
assert.equal(canalDe('subscription_call_v1'),'diagnostico');
const usage = construirActividad([event('subscription_call_v1',{provider:'agent:codex',model:'gpt-6.1-sol',cost_usd:null,prompt_tokens:null})],{ahora:1790000001000,vivo:false});
assert.match(JSON.stringify(usage), /cuota/);
const budgetEvent = event('budget_blocked_v1',{provider:'OpenCode',model:'gpt-6-luna',authorized:200,spent:200,remaining:0,reason:'cupo agotado: 200 de 200 llamadas de pago autorizadas usadas'});
panel.events=[budgetEvent,event('order_failed',{cause:'paid_budget_exhausted',reason:budgetEvent.payload.reason},2)];
assert.match(panel.renderActivity(), /Autorizar más llamadas/);
assert.match(panel.renderActivity(), /200 de 200/);
panel.events=events;
const rows = externalModelRows([{provider:'agent:codex',display:'Codex',exe:'C:/fixture/codex.exe',session:'suscripcion',models:[{slug:'gpt-6.1-sol',display_name:'Sol 6.1',manufacturer:'OpenAI',reasoning_efforts:['low','high']}]}]);
assert.equal(rows[0].free,true); assert.equal(rows[0].available,true); assert.match(rows[0].label,/suscripción/);

const budgetChildren=[];
const oldDocument=global.document;
global.document={createElement:()=>({setAttribute(){},addEventListener(kind,fn){this.click=fn;}}),dispatchEvent:e=>{global.lastBudgetEvent=e;}};
global.CustomEvent=class {constructor(type,{detail}){this.type=type;this.detail=detail;}};
const configuration = { style:{}, textContent:'', appendChild:child=>budgetChildren.push(child) };
panel.container={querySelector:()=>configuration};
panel.plan={tasks:[{},{}]};
panel.showConfiguration({allowed:true,issues:[],message:'Respaldo',budget:{authorized:201,spent:200,remaining:1},paid_roles:[true,true,false]});
assert.match(alertText(),/al menos 2/);
const authorizeButton=alertAction('Autorizar más llamadas');
assert(authorizeButton);authorizeButton.run();
assert.equal(global.lastBudgetEvent.detail,'governance');
assert.equal(global.lastBudgetEvent.type,'devagents:settings-section');
budgetChildren.length=0;
panel.showConfiguration({allowed:false,issues:[{role:'planificador',provider:'OpenCode',model:'gpt-6-luna',cause:'paid_budget_exhausted',reason:'agotado',action:'autoriza',authorized:200,spent:200,remaining:0}],message:''});
assert.match(alertText(),/200 de 200/);
assert(alertAction('Autorizar más llamadas'));
global.document=oldDocument;

panel.container = { querySelector:selector => selector === '#order-configuration' ? configuration : null };
panel.showConfiguration({allowed:false,issues:[{role:'planificador',...failure,action:'Cambia a suscripcion'}],message:''});
assert.match(alertText(),/command-a-plus/); assert.match(alertText(),/Cambia a suscripcion/);
panel.showConfiguration({allowed:true,issues:[],message:'Determinista: si el modelo falla, la orden falla'});
assert.equal(configuration.textContent,'','«Sin respaldo» vive en un chip, no en una línea fija');
(async()=>{
  const api = Object.create(CoreApi.prototype); let method;
  api.call = async name => {method=name;return {allowed:true,issues:[]};};
  await api.orderPreflight(); assert.equal(method,'core.order.preflight');
  let sent=0;
  Object.assign(panel,{phase:'idle',pendingIssue:null,core:{orderPreflight:async()=>({allowed:false,issues:[{role:'ejecutor',...failure,action:'Cambia el modelo'}]}),submitOrder:async()=>{sent++;}},pinnedRoles:{plan:''}});
  await panel.submit('Hola'); assert.equal(sent,0); assert.match(notices.at(-1),/Cambia el modelo/);
  panel.core.orderPreflight = async()=>{throw Error('bridge offline');};
  await panel.submit('Hola'); assert.equal(sent,0); assert.match(notices.at(-1),/bridge offline/);
  panel.core.orderPreflight = async()=>{panel.phase='running';return {allowed:true,issues:[],message:''};};
  await panel.submit('Hola'); assert.equal(sent,0,'overlapping preflight cannot submit twice');
  // Reach the send spy when the epoch guard is deliberately broken, without
  // replacing the submit/preflight logic under test with a mock.
  panel.setPhase = phase => { panel.phase=phase; };
  panel.toggleCancel = () => {};
  panel.fail = () => {};
  panel.turns=[];
  panel.core.submitOrder = async()=>{sent++;throw Error('unexpected send after reset');};
  panel.phase='idle'; panel.orderEpoch=1;
  panel.core.orderPreflight = async()=>{panel.orderEpoch++;return {allowed:true,issues:[],message:''};};
  await panel.submit('Hola'); assert.equal(sent,0,'reset during preflight cannot send an abandoned order');
  console.log('ORDENES UI: causes, escaping, subscription, deterministic message, bridge parity, denied and overlapping submit PASS');
})().catch(e=>{console.error(e);process.exitCode=1;});
