// el Monitor debe mostrar la version real del motor, la misma que
// la barra de estado, sin inventarla ni copiarla de un texto fijo. Antes del
// arreglo: la barra llevaba `v0.1.0` en la plantilla y el Monitor leia
// `st.version` sin normalizar; ademas el host dejaba `version` vacia cuando el
// motor corria in-proc. Este test fija el contrato de la WebUI.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

function load(name, imports = {}) {
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8'))(
    mod,
    mod.exports,
    n => imports[n] ?? {}
  );
  return mod.exports;
}

const iconStub = new Proxy({}, { get: () => () => '' });

const layout = load('layout_cab018', {
  '../design/icons': { brandMark: () => '', icons: iconStub },
  '../design/notice': { notice: () => {} },
  '../design/html': load('html_cab018'),
});

// 1. Una unica resolucion de la version, compartida por barra y Monitor.
assert.equal(typeof layout.formatEngineVersion, 'function', 'la version debe resolverse en un solo sitio');
assert.equal(layout.formatEngineVersion('0.1.0'), 'v0.1.0');
assert.equal(layout.formatEngineVersion('v0.1.0'), 'v0.1.0');
assert.equal(layout.formatEngineVersion(''), '\u2014');
assert.equal(layout.formatEngineVersion(null), '\u2014');

// 2. La barra no inventa la version: su plantilla no lleva un valor fijo.
const container = { innerHTML: '' };
layout.renderLayout(container);
assert.match(container.innerHTML, /id="status-ver"/);
assert.ok(!container.innerHTML.includes('v0.1.0'), 'la barra de estado no debe traer una version fija');

// 3. La barra refleja el payload del motor; sin version muestra «—», no un
//    valor heredado.
const verEl = { innerText: '' };
globalThis.document = { getElementById: id => (id === 'status-ver' ? verEl : null) };
const base = { online: true, pid: 10, governanceMode: 'hybrid', model: 'auto', keyLabel: '1 clave(s)' };
layout.updateEngineStatus({ ...base, version: '0.1.0' });
assert.equal(verEl.innerText, 'v0.1.0');
layout.updateEngineStatus({ ...base, version: '' });
assert.equal(verEl.innerText, '\u2014', 'sin version el motor muestra «—», no un valor heredado');

// 4. El Monitor pinta la misma version que la barra.
const { MonitorPanel } = load('monitor_panel_cab018', {
  '../design/html': load('html_cab018'),
  '../design/icons': { icons: iconStub },
  '../layout/layout': layout,
});
const panel = Object.create(MonitorPanel.prototype);
panel.errors = {};
panel.catalog = null;
panel.status = {
  running: true,
  pid: 10,
  version: '0.1.0',
  governanceMode: 'hybrid',
  activeModel: 'm',
  activeProvider: 'p',
  keyLabel: '1',
  keyCount: 1,
  providerCount: 1,
  engineReady: true,
  initError: '',
};
const conVersion = panel.renderResumen();
assert.match(conVersion, /Versi\u00f3n/);
assert.match(conVersion, /v0\.1\.0/, 'el Monitor muestra la version real del motor');
panel.status = { ...panel.status, version: '' };
assert.match(panel.renderResumen(), /\u2014/);

console.log('PASS CK-CAB-018: barra y Monitor comparten la version real del motor, sin texto fijo');
