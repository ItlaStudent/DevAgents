const assert = require('node:assert/strict');
const {externalModelRows} = require('../shell/webui/dist/external_models.test.cjs');
const agent = {provider:'agent:codex',cli:'codex',display:'Codex',exe:'C:/app/codex.exe',version:'0.159.2',session:'suscripcion',enumeration_status:'enumerated',selection_reason:'highest semver',acl_appcontainer_sids:['S-1-15-3-123-456'],authenticode:'trusted',models:[
  {slug:'gpt-6-luna',display_name:'GPT-6-Luna',manufacturer:'openai',reasoning_efforts:['low','high']},
  {slug:'gpt-6-astra',display_name:'GPT-6-Astra',manufacturer:'openai',reasoning_efforts:['high']},
]};
const rows=externalModelRows([agent]);
assert.equal(rows.length,2);
assert.equal(rows[0].model,'gpt-6-luna');
assert.equal(rows[0].group,'Codex');
assert.match(rows[0].label,/GPT-6-Luna \(tu suscripción\)/);
assert.equal(rows[0].exe,'C:/app/codex.exe');
assert.equal(rows[0].available,true);
assert.equal(externalModelRows([{...agent,session:'api_key'}])[0].available,false);
assert.match(externalModelRows([{...agent,session:'api_key'}])[0].label,/facturación API/);
assert.equal(externalModelRows([{...agent,session:'sin_sesion'}])[0].available,false);
assert.match(externalModelRows([{...agent,session:'desconocida'}])[0].label,/sesión desconocida/);
const sessionReason = 'perfil de Codex con permisos no verificables: escritor ajeno al sandbox oficial';
const blocked = externalModelRows([{...agent,session:'desconocida',session_reason:sessionReason}])[0];
assert.ok(blocked.label.includes(sessionReason));
assert.equal(blocked.available,false);
const providerReason = 'config.toml de Codex define un proveedor propio';
const providerBlocked = externalModelRows([{...agent,session:'api_key',session_reason:providerReason}])[0];
assert.ok(providerBlocked.label.includes('facturación API') && providerBlocked.label.includes(providerReason));
assert.equal(providerBlocked.available,false);
assert.deepEqual(externalModelRows([{...agent,models:undefined}]),[]);
assert.deepEqual(externalModelRows([]),[]);
assert.deepEqual(rows[0].aclSignals,['S-1-15-3-123-456']);
assert.equal(rows[0].signature,'trusted');
assert.deepEqual(externalModelRows([{...agent,acl_appcontainer_sids:undefined}])[0].aclSignals,[]);
console.log('E5.56: 15 checks passed (models, groups, billing, binary, AppContainer and signature signals)');

const opencode = {...agent,provider:'agent:opencode',cli:'opencode',display:'OpenCode',session:'api_key',models:[
  {slug:'opencode/x-free',display_name:'opencode/x-free',manufacturer:'unknown',reasoning_efforts:[],free:true,label:'OpenCode · opencode/x-free (gratis)'},
  {slug:'opencode/claude-opus-5',display_name:'opencode/claude-opus-5',manufacturer:'anthropic',reasoning_efforts:[],free:false},
]};
const [free, paid] = externalModelRows([opencode]);
assert.equal(free.available,true,'CK-CAB-002 opencode free is selectable with an API CLI session');
assert.equal(free.billingFree,true);
assert.match(free.label,/\(gratis\)/);
assert.doesNotMatch(free.label,/facturación API|bloquead/);
assert.equal(paid.available,false);
assert.match(paid.label,/facturación API: bloqueado/);
for (const session of ['sin_sesion','desconocida','suscripcion']) {
  assert.equal(externalModelRows([{...opencode,session}])[0].available,true);
}
console.log('PASS CK-CAB-002 opencode free rows are free and paid API rows stay blocked');
