// Regresión del plazo de BridgeClient.send (hallazgo cabina: una petición
// `core.*` sin respuesta dejaba el panel en "Consultando…" para siempre).
// OJO: sin el fix la promesa queda pendiente y Node saldría limpio antes del
// await (verde vacío). Por eso se sigue el asentamiento con una bandera y un
// temporizador propio que mantiene vivo el proceso.
// node tests/bridge_client_test.cjs
const { BridgeClient } = require('../shell/webui/dist/bridge_client.test.cjs');

let failed = 0;
function assert(name, cond, detail) {
  if (cond) {
    console.log(`  ok: ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${name} ${detail ? '-> ' + detail : ''}`);
  }
}
const espera = (ms) => new Promise((r) => setTimeout(r, ms));

async function main() {
  // Host presente pero mudo: postMessage existe y nunca responde.
  let posted = 0;
  globalThis.window = {
    chrome: { webview: { postMessage() { posted += 1; }, addEventListener() {} } },
  };

  const c = new BridgeClient();

  // 1) Host mudo => la promesa rechaza con la causa, no queda pendiente.
  const t0 = Date.now();
  let asentada = null;
  c.send('core.health', {}, 60)
    .then(() => { asentada = 'ok'; })
    .catch((e) => { asentada = 'err:' + e.message; });
  await espera(300);
  const ms = Date.now() - t0;
  assert('host mudo: send() rechaza en vez de quedar pendiente', asentada !== null && asentada.startsWith('err:'), `asentada=${asentada}`);
  assert('el rechazo nombra la llamada', asentada !== null && asentada.includes('core.health'), asentada);
  assert('rechazo dentro del plazo (no eterno)', ms < 5000, `tardo ${ms}ms`);
  assert('la promesa pendiente se limpia', c.pending.size === 0, `pendientes: ${c.pending.size}`);
  assert('el temporizador se limpia', c.timers.size === 0, `timers: ${c.timers.size}`);
  assert('la petición sí se envió al host', posted === 1, `posted: ${posted}`);

  // 2) Respuesta normal => resuelve y el temporizador no dispara después.
  const c2 = new BridgeClient();
  const p = c2.send('core.status', {}, 200);
  c2.onHostMessage({ id: 1, status: 'ok', payload: { engineReady: true } });
  const r = await p;
  assert('respuesta normal resuelve', r && r.status === 'ok');
  assert('sin pendientes tras resolver', c2.pending.size === 0);
  await espera(260);
  assert('el temporizador muerto no rechaza tarde', c2.pending.size === 0);

  // 3) Respuesta tardía tras timeout: no hay handler, no explota.
  const c3 = new BridgeClient();
  let asentada3 = null;
  c3.send('core.catalog.info', {}, 40).catch((e) => { asentada3 = 'err'; });
  await espera(80);
  c3.onHostMessage({ id: 1, status: 'ok', payload: {} });
  await espera(20);
  assert('respuesta tardía tras timeout no explota', asentada3 === 'err', `asentada3=${asentada3}`);

  if (failed) {
    console.error(`\n${failed} comprobaciones FALLARON`);
    process.exit(1);
  }
  console.log('\nOK: plazo de BridgeClient verificado');
}

main().catch((e) => { console.error('FAIL: excepción en el test', e); process.exit(1); });
