const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
function load(name) {
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(path.resolve(__dirname, `../shell/webui/dist/${name}.test.cjs`), 'utf8'))(mod, mod.exports, () => ({}));
  return mod.exports;
}
const { MissionControlPanel } = load('mission_control_vision');
const { CoreApi } = load('core_api_vision');
assert.equal(typeof CoreApi.prototype.visionProbe, 'function', 'E5.24: falta acción del puente para medir visión');
let checks = 0;
function element() { return { textContent: '', style: {}, disabled: false, listeners: {}, addEventListener(name, cb) { this.listeners[name] = cb; } }; }
function panel() {
  const p = Object.create(MissionControlPanel.prototype);
  const button = element(), status = element();
  Object.assign(p, { phase: 'idle', pinnedRoles: { exec: '', plan: '', audit: 'ignored|auditor' }, visionProbeBusy: false, visionProbeText: '' });
  p.container = { querySelector: s => ({ '#btn-vision-probe': button, '#vision-probe-status': status })[s] ?? null, addEventListener() {} };
  return { p, button, status };
}
(async () => {
  const api = Object.create(CoreApi.prototype); let request;
  api.call = (method, params) => { request = { method, params }; return Promise.resolve({ provider: 'p', model: 'm', status: 'ok', cap_vision_status: 'yes' }); };
  await api.visionProbe('p', 'm'); assert.deepEqual(request, { method: 'core.vision.probe', params: { provider: 'p', model: 'm' } }); checks++; console.log('ok API envía proveedor y modelo exactos');
  api.call = async () => { throw new Error('provider unavailable'); };
  await assert.rejects(api.visionProbe('p', 'm'), /provider unavailable/); checks++; console.log('ok API propaga errores del motor');
  const { p, button, status } = panel(); let calls = 0, release;
  p.core = { visionProbe(provider, model) { calls++; return new Promise(resolve => { release = () => resolve({ provider, model, status: 'ok', cap_vision_status: 'yes' }); }); } };
  p.bindShell(); assert.equal(calls, 0); assert.equal(typeof button.listeners.click, 'function'); checks++; console.log('ok botón conectado sin sondas automáticas');
  await p.probeSelectedVision(); assert.equal(calls, 0); assert.match(status.textContent, /Elige/); checks++; console.log('ok sin modelo no elige uno por cuenta propia');
  p.pinnedRoles = { exec: 'free-provider|exec-model', plan: 'other|plan-model', audit: 'ignored|auditor' };
  const pending = p.probeSelectedVision(); assert.equal(calls, 1); assert.equal(button.disabled, true); assert.match(status.textContent, /free-provider.*exec-model.*Midiendo/); checks++; console.log('ok estado pendiente visible con ejecutor elegido');
  await p.probeSelectedVision(); assert.equal(calls, 1); checks++; console.log('ok clic duplicado no lanza otra sonda');
  release(); await pending; assert.equal(button.disabled, false); assert.match(status.textContent, /free-provider.*exec-model.*sí/); checks++; console.log('ok resultado sí medido visible');
  let chosen;
  p.pinnedRoles.exec = '';
  p.core.visionProbe = async (provider, model) => { chosen = [provider, model]; return { provider, model, status: 'ok', cap_vision_status: 'no', reason: 'color incorrecto' }; };
  await p.probeSelectedVision(); assert.deepEqual(chosen, ['other', 'plan-model']); assert.match(status.textContent, /Visión medida: no.*color incorrecto/); checks++; console.log('ok hereda pin de orden y muestra no con causa');
  p.core.visionProbe = async (provider, model) => ({ provider, model, status: 'skipped', cap_vision_status: 'not_probed', reason: '<img onerror=bad>' });
  await p.probeSelectedVision(); assert.match(status.textContent, /Visión sin medir.*<img onerror=bad>/); checks++; console.log('ok skipped no se disfraza de medición y razón es texto');
  p.core.visionProbe = async () => { throw new Error('host unavailable'); };
  await p.probeSelectedVision(); assert.equal(button.disabled, false); assert.match(status.textContent, /Visión sin medir.*host unavailable/); checks++; console.log('ok error de puente visible y permite reintento');
  p.core.visionProbe = async () => ({ provider: 'wrong', model: 'wrong', status: 'ok', cap_vision_status: 'yes' });
  await p.probeSelectedVision(); assert.match(status.textContent, /no corresponde/); checks++; console.log('ok resultado de otro modelo no acredita el seleccionado');
  p.core = null; await p.probeSelectedVision(); assert.match(status.textContent, /puente/); checks++; console.log('ok sin puente no mide');
  let clicked = false;
  p.core = { visionProbe: async (provider, model) => { clicked = true; return { provider, model, status: 'ok', cap_vision_status: 'yes' }; } };
  button.listeners.click(); await new Promise(resolve => setImmediate(resolve)); assert.equal(clicked, true); assert.match(status.textContent, /Visión medida: sí/); checks++; console.log('ok pulsar botón ejecuta la sonda y actualiza estado');
  console.log(`${checks} checks PASS`);
})().catch(error => { console.error(error); process.exitCode = 1; });
