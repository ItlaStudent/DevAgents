// UI-ACTION: prueba del allowlist del dispatcher de la cabina.
//
// El motor ya valida al escribir el evento; la cabina RE-valida antes de tocar
// la UI (defensa en profundidad). Aquí se ejercita esa segunda puerta: acciones
// válidas se aplican y se acusan con ok:true; todo lo demás se rechaza con
// ok:false y un detalle, sin excepción.

// Stubs DOM mínimos para `notice()` (toasts) — el módulo es browser-side.
const fakeEl = () => ({
  id: '',
  style: { cssText: '' },
  setAttribute() {},
  appendChild() {},
  remove() {},
  childElementCount: 0,
  firstElementChild: null,
  textContent: '',
});
globalThis.document = {
  getElementById: () => null,
  createElement: fakeEl,
  body: { appendChild() {} },
};
globalThis.requestAnimationFrame = (fn) => setTimeout(fn, 0);
globalThis.window = { setInterval, clearInterval, setTimeout, clearTimeout };

const { UiActionDispatcher } = require('../shell/webui/dist/ui_actions.test.cjs');

let failed = 0;
function check(cond, label) {
  if (cond) {
    console.log(`  ok: ${label}`);
  } else {
    failed++;
    console.log(`  FALLO: ${label}`);
  }
}

async function main() {
  const acks = [];
  const calls = { themes: [], views: [], sessions: [] };
  const core = {
    uiActions: async () => [],
    uiActionAck: async (actionId, ok, detail) => {
      acks.push({ actionId, ok, detail });
      return { ok: true };
    },
  };
  const deps = {
    applyTheme: (t) => calls.themes.push(t),
    hasTheme: (t) => ['dark', 'light', 'nord', 'midnight'].includes(t),
    showView: (v) => calls.views.push(v),
    focusSession: (s) => calls.sessions.push(s),
  };
  const d = new UiActionDispatcher(core, deps);

  // 1. set_theme válido -> se aplica y ack ok.
  await d.handleOrderEvent(10, { action: 'set_theme', args: { theme: 'nord' } });
  check(calls.themes.length === 1 && calls.themes[0] === 'nord', 'set_theme aplica el tema');
  check(acks.length === 1 && acks[0].ok === true && acks[0].actionId === 10, 'ack ok:true con el id del evento');

  // 2. Tema desconocido -> rechazado, sin tocar applyTheme.
  await d.handleOrderEvent(11, { action: 'set_theme', args: { theme: 'rainbow' } });
  check(calls.themes.length === 1, 'tema desconocido no se aplica');
  check(acks[1].ok === false && /desconocido/.test(acks[1].detail), 'ack ok:false con detalle');

  // 3. Acción fuera del allowlist -> rechazada (nunca ejecuta nada extraño).
  await d.handleOrderEvent(12, { action: 'set_permission_config', args: { text: 'x' } });
  check(acks[2].ok === false, 'set_permission_config rechazada');
  check(calls.views.length === 0 && calls.sessions.length === 0, 'acción rechazada no tocó la UI');

  // 4. open_view válido e inválido.
  await d.handleOrderEvent(13, { action: 'open_view', args: { view: 'settings' } });
  check(calls.views[0] === 'settings' && acks[3].ok === true, 'open_view settings aplicada');
  await d.handleOrderEvent(14, { action: 'open_view', args: { view: '../../etc' } });
  check(acks[4].ok === false && calls.views.length === 1, 'open_view con vista hostil rechazada');

  // 5. focus_session: solo ids numéricos.
  await d.handleOrderEvent(15, { action: 'focus_session', args: { session_id: '42' } });
  check(calls.sessions[0] === '42' && acks[5].ok === true, 'focus_session numérico aplicado');
  await d.handleOrderEvent(16, { action: 'focus_session', args: { session_id: '1; DROP TABLE' } });
  check(acks[6].ok === false && calls.sessions.length === 1, 'focus_session inyectado rechazado');

  // 6. notify con texto -> ok; notify vacío -> rechazado.
  await d.handleOrderEvent(17, { action: 'notify', args: { text: 'build terminado' } });
  check(acks[7].ok === true, 'notify con texto aplica');
  await d.handleOrderEvent(18, { action: 'notify', args: { text: '' } });
  check(acks[8].ok === false, 'notify vacío rechazado');

  // 7. Payloads malformados -> rechazados, nunca lanzan.
  await d.handleOrderEvent(19, null);
  check(acks[9].ok === false, 'payload null rechazado');
  await d.handleOrderEvent(20, {});
  check(acks[10].ok === false, 'payload sin action rechazado');
  await d.handleOrderEvent(21, { action: 'set_theme' });
  check(acks[11].ok === false, 'set_theme sin args rechazado');

  // 8. Todos los acks llevaron el id del evento correspondiente.
  check(acks.every((a, i) => a.actionId === 10 + i), 'cada ack correlaciona su evento');

  // 9. T8: el agente pide ver el grafo de su orden. Solo vista:
  // sin el manejador la cabina lo rechaza; con él, se llama y nada más.
  await d.handleOrderEvent(22, { action: 'open_view', args: { view: 'order_graph' } });
  check(acks[12].ok === false && /grafo/.test(acks[12].detail), 'order_graph sin manejador rechazado');
  let graphs = 0;
  const acks2 = [];
  const d2 = new UiActionDispatcher({ uiActions: async () => [], uiActionAck: async (actionId, ok, detail) => { acks2.push({ actionId, ok, detail }); return { ok: true }; } },
    { ...deps, showOrderGraph: () => { graphs += 1; } });
  await d2.handleOrderEvent(30, { action: 'open_view', args: { view: 'order_graph' } });
  check(graphs === 1 && acks2[0].ok === true, 'open_view order_graph muestra el grafo');
  check(calls.views.length === 1 && calls.themes.length === 1 && calls.sessions.length === 1, 'order_graph no toca otras vistas, temas ni sesiones');
  await d2.handleOrderEvent(31, { action: 'open_view', args: { view: 'order_graph<script>' } });
  check(graphs === 1 && acks2[1].ok === false, 'variante hostil de order_graph rechazada');

  if (failed === 0) {
    console.log('TODAS PASAN');
  } else {
    console.log(`${failed} comprobaciones FALLARON`);
    process.exit(1);
  }
}

main().catch((e) => {
  console.log('excepción no esperada:', e);
  process.exit(1);
});
