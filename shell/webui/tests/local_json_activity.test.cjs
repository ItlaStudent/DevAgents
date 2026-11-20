// Fixture sintético: clasificación y markup real, sin cabina ni modelos.
// Desde shell/webui: node tests/local_json_activity.test.cjs
const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const ts = require('typescript');
// Compilador instalado, sin bundler ni servidor. El typecheck se ejecuta aparte.
require.extensions['.ts'] = (module, filename) => {
  const source = ts.transpileModule(readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 },
    fileName: filename,
  });
  module._compile(source.outputText, filename);
};
const { construirActividad, canalDe } = require('../src/chat_activity.ts');
const { MissionControlPanel } = require('../src/panes/mission_control.ts');
const base = { provider: 'Ollama', model: 'local-fixture', reason: 'Falta tasks <script>alert(1)</script>' };
const events = ['local_json_retry', 'local_json_fallback', 'local_json_failed'].map((kind, i) => ({
  id: i + 1, ts: 1790000000000 + i, source: 'motor', kind,
  payload: { ...base, ...(kind === 'local_json_fallback' ? { to_provider: 'Nube fixture', to_model: 'modelo-destino' } : {}) },
}));
for (const event of events) assert.equal(canalDe(event.kind), 'diagnostico');
const activity = construirActividad(events, { ahora: 1790000001000, vivo: false });
assert.equal(activity.desconocidos.length, 0);
assert.equal(activity.operaciones.length, 3);
assert.match(activity.operaciones[0].titulo, /un único reintento/);
assert.match(activity.operaciones[1].detalle, /Siguiente modelo: Nube fixture · modelo-destino/);
assert.equal(activity.operaciones[2].estado, 'fallo');
assert.equal(activity.bloqueos.length, 0, 'El aviso no inventa un bloqueo global de la orden');
const panel = Object.create(MissionControlPanel.prototype);
Object.assign(panel, { events, orderId: 42, phase: 'error', activityOpen: false, activityFilter: '', activityShowAll: false });
const html = panel.renderActivity();
const noticeIndex = html.indexOf('data-local-json-notice="local-json:3"');
assert(noticeIndex >= 0 && noticeIndex < html.indexOf('<details id="turn-activity"'));
assert(html.includes('data-local-json-order="42"'));
assert(html.includes('intentos agotados'));
assert(html.includes('&lt;script&gt;alert(1)&lt;/script&gt;'));
assert(!html.includes('<script>'));
assert(html.includes('modelo-destino'), 'El destino anterior sigue en el historial');
for (let i = 0; i < events.length; i++) {
  panel.events = [events[i]];
  const single = panel.renderActivity();
  assert(single.includes(`data-local-json-notice="local-json:${i + 1}"`));
  assert(single.includes(activity.operaciones[i].titulo));
  assert(single.includes('local-fixture'));
}
const legacy = construirActividad([{ ...events[0], payload: undefined, payload_json: JSON.stringify({ provider: 'Ollama', model: 'viejo', contract: 'plan' }) }], { ahora: 1790000001000, vivo: false });
assert.match(legacy.operaciones[0].detalle, /formato JSON requerido/);
assert.match(legacy.operaciones[0].detalle, /plan/);
panel.events = [];
assert.equal(panel.renderActivity(), '');
console.log('E5.03 UI fixture: clasificación, historial, aviso persistente y escape correctos; sin cabina/modelos. EXIT_CODE=0');
