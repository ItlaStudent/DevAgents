// Vista previa del panel de actividad con eventos de prueba.
//
//   node build_preview_activity.mjs <carpeta-destino> [ruta-eventos.json]
//   # luego: servir esa carpeta y abrir index.html?escena=<nombre>
//
// Escenas: `ejecutando`, `finalPlegado`, `detalleAbierto`.
import * as esbuild from 'esbuild';
import * as fs from 'fs';
import * as path from 'path';

const out = process.argv[2];
if (!out) {
  console.error('Uso: node build_preview_activity.mjs <carpeta-destino> [eventos.json]');
  process.exit(2);
}
const trazaPath = process.argv[3] || new URL('./tests/fixtures/activity-preview.json', import.meta.url);

fs.mkdirSync(out, { recursive: true });
const traza = JSON.parse(fs.readFileSync(trazaPath, 'utf8'));
const eventos = traza.events || traza;

const source = `
import { injectStylesheet } from './design/stylesheet';
import { ThemeManager } from './design/theme_registry';
import { MissionControlPanel } from './panes/mission_control';

const EVENTOS = ${JSON.stringify(eventos)};
const CORTE_EN_EJECUCION = EVENTOS.findIndex((evento) => evento.kind === 'order_failed');

injectStylesheet();
const tm = new ThemeManager();
tm.applyTheme(tm.getCurrentThemeId());

const panel = new MissionControlPanel(document.getElementById('app'));
const p = panel;

// Los instantes se desplazan para que el ultimo evento DE LA ESCENA caiga
// ahora. Si se desplazara contra el ultimo de la traza entera, una escena
// «en ejecucion» cortada a mitad mediria hasta el final de la orden y diria
// 7 min donde los eventos que se ven llevan 3. Lo encontro la auditoria de la
// cabina el 09-09 comparando la captura con los timestamps reales.
function conRelojDeLaEscena(lista) {
  const plausibles = lista.map((e) => e.ts).filter((t) => typeof t === 'number' && t >= 1000000000000);
  if (!plausibles.length) return lista;
  const delta = Date.now() - Math.max(...plausibles);
  return lista.map((e) =>
    typeof e.ts === 'number' && e.ts >= 1000000000000 ? { ...e, ts: e.ts + delta } : e
  );
}

function pintar(fase, lista, abierto, turnos) {
  const eventos = conRelojDeLaEscena(lista);
  p.phase = fase;
  p.events = eventos;
  p.orderId = 437;
  p.startedAt = Date.now() - (eventos.length ? 452000 : 0);
  p.turns = turnos;
  p.activityOpen = abierto;
  p.errorText = fase === 'error'
    ? 'La ejecución terminó con errores. Revisa la actividad del motor y el ledger.'
    : '';
  p.renderBody();
}

const TURNO_USUARIO = {
  role: 'user',
  text: 'crea index.html, styles.css, app.js y test_app.js: una calculadora web que sume, reste, multiplique, divida y borre.',
};

window.escena = {
  // A mitad de la orden: la actividad está abierta y el turno sigue vivo.
  ejecutando() { pintar('running', EVENTOS.slice(0, CORTE_EN_EJECUCION < 0 ? undefined : CORTE_EN_EJECUCION), null, [TURNO_USUARIO]); },
  // La tarjeta de error y los bloqueos se calculan en el panel.
  finalPlegado() { pintar('error', EVENTOS, null, [TURNO_USUARIO]); },
  detalleAbierto() {
    window.escena.finalPlegado();
    p.activityOpen = true;
    p.renderBody();
  },
};

const cual = new URLSearchParams(location.search).get('escena') || 'ejecutando';
(window.escena[cual] || window.escena.ejecutando)();
`;

await esbuild.build({
  stdin: { contents: source, resolveDir: path.resolve('src'), loader: 'ts' },
  bundle: true,
  outfile: path.join(out, 'preview.js'),
  format: 'iife',
  target: 'chrome110',
  logLevel: 'info',
});

fs.writeFileSync(
  path.join(out, 'index.html'),
  `<!DOCTYPE html><html lang="es"><head><meta charset="UTF-8">
<title>DevAgents · actividad del turno</title>
<style>:root{color-scheme:dark}html,body{margin:0;height:100%;background:#0d0e10}
#app{height:100vh;width:100%}</style></head>
<body><div id="app"></div><script src="preview.js"></script></body></html>`
);
console.log('arnes de captura listo en', out);
