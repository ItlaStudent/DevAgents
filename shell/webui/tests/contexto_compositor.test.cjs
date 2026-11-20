// — indicador de contexto del compositor.
// Lo encadena cabina_ux.test.cjs (paso test-webui de build.zig, build_ux_test.mjs).
//
// Cubre: umbrales 70/90 con sus colores, actualización al añadir/quitar chips y
// tras cada mensaje, aviso y «Compactar ahora» al pasar el 75 %, y la
// coherencia con la tarjeta «Contexto» del panel derecho (mismo número, mismo
// color) en Chromium real por CDP con el componente y la hoja reales.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

function load(name, imports = {}) {
  const mod = { exports: {} };
  new Function('module', 'exports', 'require', fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8'))(mod, mod.exports, n => imports[n] ?? {});
  return mod.exports;
}

const ctx = load('context_usage');
const autoc = load('auto_compact_ux');
const { MissionControlPanel } = load('mission_control_ux', {
  '../design/html': load('html_ux'),
  '../design/notice': { notice: () => {} },
  '../design/alerts': { raiseAlert: () => {}, clearAlert: () => {}, clearAlertsExcept: () => {} },
  '../design/icons': { icons: new Proxy({}, { get: () => () => '' }) },
  '../design/orbit_backdrop': { orbitBackdrop: () => '' },
  './auto_compact': autoc,
  './context_usage': ctx,
});

// 32768 tokens de ventana x 4 caracteres por token: el 1 % son 1310,72 caracteres.
const charsPara = pct => Math.round((pct / 100) * 32768 * 4);

// ---- costuras DOM mínimas para el panel ------------------------------------
const published = [];

function el(extra = {}) {
  return { hidden: false, dataset: {}, innerHTML: '', listeners: {}, addEventListener(n, f) { this.listeners[n] = f; }, focus() {}, querySelectorAll() { return []; }, ...extra };
}
function panel({ turnChars = [], attachments = [] } = {}) {
  const p = Object.create(MissionControlPanel.prototype);
  const meter = el();
  const chips = el();
  Object.assign(p, {
    turns: turnChars.map((n, i) => ({ role: i % 2 ? 'assistant' : 'user', text: 'x'.repeat(n) })),
    attachments, attachError: '', autoCompact: autoc.estadoInicial(),
  });
  p.container = { querySelector: s => ({ '#composer-context': meter, '#composer-chips': chips }[s] ?? null) };
  return { p, meter, chips };
}
const lastDetail = () => published.at(-1).detail;
const fillColor = html => (html.match(/class="ctx-meter__fill" style="width:(\d+)%;background:(#[0-9A-F]{6})"/) || [])[2];

async function main() {
  // Costuras globales solo durante esta prueba: las demás del encadenado no las ven.
  const previous = { CustomEvent: global.CustomEvent, document: global.document };
  global.CustomEvent = class { constructor(type, init) { this.type = type; this.detail = init && init.detail; } };
  global.document = { dispatchEvent: e => { published.push(e); return true; } };
  try {
    await grupos();
  } finally {
    for (const k of Object.keys(previous)) { if (previous[k] === undefined) delete global[k]; else global[k] = previous[k]; }
  }
}

async function grupos() {
  let checks = 0;
  const ok = msg => { checks++; console.log('PASS contexto-compositor: ' + msg); };

  // 1. Umbrales: verde <=70, amarillo >70, rojo >90, con la hoja de la referencia.
  const palette = { ok: '#79996A', aviso: '#C89246', critico: '#C4553D' };
  for (const [pct, nivel] of [[0, 'ok'], [50, 'ok'], [70, 'ok'], [71, 'aviso'], [75, 'aviso'], [90, 'aviso'], [91, 'critico'], [100, 'critico']]) {
    assert.equal(ctx.nivelContexto(pct), nivel, `nivel de ${pct} %`);
    assert.equal(ctx.colorContexto(pct), palette[nivel], `color de ${pct} %`);
  }
  ok('umbrales 70/90 (70 verde, 71 amarillo, 90 amarillo, 91 rojo) y colores #79996A/#C89246/#C4553D');

  // 2. La estimación es la de auto_compact: ni se duplica ni cambia.
  for (const n of [0, 4, 1000, 91750, 98304, 200000, 10 ** 7]) {
    const uso = ctx.usoContexto(n, 2, 0);
    assert.equal(uso.pct, autoc.porcentajeContexto(n), `pct de ${n}`);
    assert.equal(uso.tokens, autoc.tokensEstimados(n), `tokens de ${n}`);
  }
  assert.equal(ctx.usoContexto(0, 0, 0).pct, null, 'sin hilo ni adjuntos no se inventa 0 %');
  ok('mismo porcentaje y tokens que auto_compact.ts (porcentajeContexto/tokensEstimados)');

  // 3. Indicador pintado por el panel real: valor, color, «Estimado», aria-label.
  for (const [pct, color] of [[70, '#79996A'], [71, '#C89246'], [90, '#C89246'], [91, '#C4553D']]) {
    const { p, meter } = panel({ turnChars: [charsPara(pct), 0] });
    p.publishThreadUsage();
    assert.equal(meter.hidden, false);
    assert.equal(lastDetail().pct, pct, `se publica ${pct}`);
    assert.match(meter.innerHTML, new RegExp(`data-ctx-pct>${pct} %</span>`));
    assert.match(meter.innerHTML, /<span class="ctx-meter__label">Estimado<\/span>/);
    assert.match(meter.innerHTML, new RegExp(`aria-label="Contexto usado: ${pct} % \\(estimado\\)"`));
    assert.match(meter.innerHTML, new RegExp(`aria-valuenow="${pct}"`));
    assert.equal(fillColor(meter.innerHTML), color, `color a ${pct} %`);
    assert.equal(meter.dataset.pct, String(pct));
  }
  ok('el indicador muestra % + «Estimado» + aria-label y el color de su umbral');

  // 4. Sin hilo: oculto, sin número inventado.
  {
    const { p, meter } = panel();
    p.publishThreadUsage();
    assert.equal(meter.hidden, true);
    assert.equal(meter.innerHTML, '');
    assert.equal(lastDetail().pct, null);
  }
  ok('sin hilo ni chips el indicador se oculta (pct null, igual que la tarjeta)');

  // 5. Tras cada mensaje: el hilo crece y renderBody vuelve a publicar.
  {
    const { p, meter } = panel({ turnChars: [charsPara(10), 0] });
    p.container.querySelector = (s) => (s === '#composer-context' ? meter : null);
    p.publishThreadUsage();
    assert.equal(lastDetail().pct, 10);
    p.turns.push({ role: 'assistant', text: 'y'.repeat(charsPara(20)) });
    p.publishThreadUsage();
    assert.equal(lastDetail().pct, 30);
    assert.match(meter.innerHTML, /data-ctx-pct>30 %<\/span>/);
    // renderBody es el punto por el que pasa cada mensaje: su primera línea publica.
    const source = MissionControlPanel.prototype.renderBody.toString();
    assert.match(source.slice(0, 400), /publishThreadUsage\(\)/, 'renderBody publica el uso al repintar');
  }
  ok('el valor sube tras un mensaje nuevo y renderBody publica en cada repintado');

  // 6. Añadir y quitar chips (adjuntos): mueve el número, con el renderChips real.
  {
    const rm = el({ dataset: { rm: '0' } });
    const base = charsPara(60);
    const { p, meter, chips } = panel({ turnChars: [base, 0] });
    chips.querySelectorAll = () => [rm];
    p.renderChips();
    const antes = lastDetail().pct;
    assert.equal(antes, 60);
    p.attachments.push({ name: 'notas.txt', content: 'z'.repeat(charsPara(15)) });
    p.renderChips();
    assert.equal(lastDetail().pct, 75, 'un adjunto de texto del 15 % sube de 60 a 75');
    assert.match(meter.innerHTML, /data-ctx-pct>75 %<\/span>/);
    assert.ok(lastDetail().chars > base, 'los chars publicados incluyen el adjunto');
    rm.listeners.click();
    assert.equal(p.attachments.length, 0);
    assert.equal(lastDetail().pct, 60, 'quitar el chip devuelve el número');
    assert.match(meter.innerHTML, /data-ctx-pct>60 %<\/span>/);
    // Imagen: ~píxeles/750 tokens, acotado a 1600 (un 4,9 % de la ventana).
    p.attachments.push({ name: 'a.png', data_base64: 'x', mime: 'image/png', ext: 'png', width: 2000, height: 2000 });
    p.renderChips();
    assert.equal(lastDetail().pct, 65, 'una imagen grande suma 1600 tokens estimados');
  }
  ok('añadir/quitar chips actualiza el indicador y lo publicado (texto e imagen)');

  // 7. Aviso y «Compactar ahora» al pasar el umbral del 75 %.
  {
    const { p, meter } = panel({ turnChars: [charsPara(74), 0] });
    p.publishThreadUsage();
    assert.ok(!/ctx-meter__warn/.test(meter.innerHTML) && !/composer-context-compact/.test(meter.innerHTML), 'a 74 % sin aviso ni botón');
    p.turns.push({ role: 'user', text: 'x'.repeat(charsPara(2)) });
    p.publishThreadUsage();
    assert.equal(lastDetail().pct, 76);
    assert.match(meter.innerHTML, /<span class="ctx-meter__warn" role="status">Contexto casi lleno: se compactará sola al 75 %<\/span>/);
    assert.match(meter.innerHTML, /<button[^>]*id="composer-context-compact"[^>]*>Compactar ahora<\/button>/);
    // Con un único turno no hay nada que resumir: aviso sí, botón no.
    const solo = panel({ turnChars: [charsPara(80)] });
    solo.p.publishThreadUsage();
    assert.match(solo.meter.innerHTML, /ctx-meter__warn/);
    assert.ok(!/composer-context-compact/.test(solo.meter.innerHTML), 'un turno: sin botón (compactConversation no haría nada)');
    // En vuelo: se anuncia y no se ofrece otra compactación encima.
    p.autoCompact = autoc.enMarcha(p.autoCompact);
    p.publishThreadUsage();
    assert.match(meter.innerHTML, /Compactando el hilo…/);
    assert.ok(!/composer-context-compact/.test(meter.innerHTML));
  }
  ok('al pasar el 75 % aparece el aviso y «Compactar ahora» (solo con >=2 turnos y nada en vuelo)');

  // 8. El botón llama a la MISMA acción que ya existía: compactConversation.
  {
    const meter = el();
    const input = el(), send = el();
    const { p } = panel({ turnChars: [charsPara(80), 0] });
    p.phase = 'idle'; p.hooks = {}; p.core = null;
    p.container = { querySelector: s => ({ '#composer-context': meter, '#mission-composer-input': input, '#btn-mission-send': send }[s] ?? null), addEventListener() {} };
    let calls = 0;
    p.compactConversation = () => { calls++; return Promise.resolve(); };
    p.bindShell();
    assert.equal(typeof meter.listeners.click, 'function', 'el indicador escucha clics');
    meter.listeners.click({ target: { closest: () => null } });
    assert.equal(calls, 0, 'un clic fuera del botón no compacta');
    meter.listeners.click({ target: { closest: sel => (sel === '#composer-context-compact' ? {} : null) } });
    assert.equal(calls, 1, 'el botón invoca compactConversation');
    const src = MissionControlPanel.prototype.compactConversation.toString();
    assert.match(src, /submitOrder\(prompt, COMPACTION_PROJECT/, 'sigue siendo el flujo actual (sin operación nueva del puente)');
  }
  ok('«Compactar ahora» del compositor invoca compactConversation (la acción existente)');

  // 9. Coherencia con la tarjeta Contexto del panel derecho (Chromium por CDP).
  const scenarios = [];
  for (const [nombre, cfg] of [
    ['sin hilo', { turnChars: [] }],
    ['70 %', { turnChars: [charsPara(70), 0] }],
    ['71 %', { turnChars: [charsPara(71), 0] }],
    ['75 %', { turnChars: [charsPara(75), 0] }],
    ['90 %', { turnChars: [charsPara(90), 0] }],
    ['91 %', { turnChars: [charsPara(91), 0] }],
    ['60 % + chip de texto', { turnChars: [charsPara(60), 0], attachments: [{ name: 'a.txt', content: 'q'.repeat(charsPara(12)) }] }],
    ['solo chips', { turnChars: [], attachments: [{ name: 'a.txt', content: 'q'.repeat(charsPara(30)) }] }],
    ['saturado', { turnChars: [charsPara(300), 0] }],
  ]) {
    const { p, meter } = panel(cfg);
    p.publishThreadUsage();
    scenarios.push({ nombre, detail: lastDetail(), meterHidden: meter.hidden, meterHtml: meter.innerHTML });
  }
  await coherenciaConTarjeta(scenarios);
  ok(`indicador y tarjeta «Contexto» muestran el mismo número y color (${scenarios.length} escenarios, Chromium)`);

  console.log(`CK-VER1-006: ${checks} grupos de comprobación PASS`);
}

async function coherenciaConTarjeta(scenarios) {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-ver1006-'));
  const executable = resolveBrowser();
  const html = path.join(profile, 'ctx.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map();
  child.stderr.on('data', d => { stderr += d; });
  const fail = error => { for (const r of pending.values()) { clearTimeout(r.timer); r.reject(error); } pending.clear(); };
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      const r = pending.get(message.id);
      if (r) { clearTimeout(r.timer); pending.delete(message.id); message.error ? r.reject(Error(JSON.stringify(message.error))) : r.resolve(message.result); }
    }
  });
  const send = (method, params = {}, sessionId = session) => new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 15000);
    pending.set(id, { resolve, reject, timer });
    child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
  });
  const evaluate = async expression => {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  };
  try {
    const { targetId } = await send('Target.createTarget', { url: pathToFileURL(html).href }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    {
      // Esperar a que el documento pedido sustituya al about:blank inicial: con
      // solo readyState, la navegación podía llegar después y borrar el estado
      // ya montado (rojos intermitentes del 13 y 14-nov, update_ui y right_cards).
      const deadline = Date.now() + 10000;
      const ready = () => evaluate("location.href!=='about:blank' && document.readyState==='complete' && document.head!==null")
        .catch(error => { if (/context was destroyed|Cannot find context/i.test(error.message)) return false; throw error; });
      while (!await ready()) {
        if (Date.now() >= deadline) throw new Error('Timeout esperando el documento de la prueba');
        await new Promise(resolve => setTimeout(resolve, 25));
      }
    }
    await send('Emulation.setDeviceMetricsOverride', { width: 1024, height: 768, deviceScaleFactor: 1, mobile: false });
    const component = fs.readFileSync(path.join(__dirname, '../dist/ctx_right_cards.test.cjs'), 'utf8');
    const styles = fs.readFileSync(path.join(__dirname, '../dist/ctx_styles.test.cjs'), 'utf8');
    await evaluate(`(() => {
      const root = document.documentElement.style;
      const vars = {'--surface-1':'#131312','--surface-2':'#1E1D1B','--border':'rgba(250,247,244,0.07)','--border-strong':'rgba(250,247,244,0.16)','--fg':'#F2EFE9','--fg-muted':'#C7C1B8','--fg-subtle':'#9A958E','--accent':'#D9D3C7','--accent-soft':'rgba(217,211,199,0.2)','--accent-contrast':'#0A0A0A','--bg-panel':'#111110','--bg-main':'#0A0A0A'};
      for (const [k,v] of Object.entries(vars)) root.setProperty(k, v);
      const st = {exports:{}}; new Function('module','exports',${JSON.stringify(styles)})(st, st.exports); st.exports.injectStylesheet();
      const comp = {exports:{}}; new Function('module','exports',${JSON.stringify(component)})(comp, comp.exports);
      document.body.innerHTML = '<div id="rc"></div><div id="composer"><div class="ctx-meter" id="composer-context" hidden></div></div>';
      const core = { async listDir(){return {root:'C:\\\\p',entries:[]};}, async gitBranch(){return {root:'C:\\\\p',isRepo:true,branch:'main'};}, async gitStatus(){return {root:'C:\\\\p',isRepo:true,branch:'main',added:0,removed:0,files:[]};}, async gitCommit(){return {};}, async remoteStatus(){return {running:false,url:'',pid:0};}, async listArtifacts(){return [];}, async cancelOrder(){return {cancelled:false};} };
      const actions = { togglePanel(){}, toggleTerminal(){}, toggleBrowser(){}, showExplorer(){}, showMenu(){}, activeOrderId(){return 0;} };
      window.rc = new comp.exports.RightCardsPanel(document.getElementById('rc'), core, actions);
      return true;
    })()`);
    await evaluate('new Promise(r=>setTimeout(r,100))');
    for (const s of scenarios) {
      const r = await evaluate(`(() => {
        const s = ${JSON.stringify(s)};
        const host = document.getElementById('composer-context');
        host.hidden = s.meterHidden; host.innerHTML = s.meterHtml;
        document.dispatchEvent(new CustomEvent('devagents:thread-usage', { detail: s.detail }));
        const card = document.querySelector('#rc .rc-context__pct');
        const cardFill = document.querySelector('#rc .rc-context__fill');
        const meterPct = host.querySelector('[data-ctx-pct]');
        const meterFill = host.querySelector('.ctx-meter__fill');
        const gauge = host.querySelector('[role="meter"]');
        return {
          cardPct: card && card.textContent,
          cardColor: cardFill && getComputedStyle(cardFill).backgroundColor,
          cardNow: document.querySelector('#rc .rc-context__track').getAttribute('aria-valuenow'),
          meterVisible: !host.hidden && getComputedStyle(host).display !== 'none',
          meterPct: meterPct && meterPct.textContent,
          meterColor: meterFill && getComputedStyle(meterFill).backgroundColor,
          meterNow: gauge && gauge.getAttribute('aria-valuenow'),
          label: gauge && gauge.getAttribute('aria-label'),
          cardLabel: document.querySelector('#rc .rc-context__label').textContent,
        };
      })()`);
      if (s.detail.pct === null) {
        assert.equal(r.cardPct, '—', `${s.nombre}: la tarjeta no inventa un 0 %`);
        assert.equal(r.meterVisible, false, `${s.nombre}: el indicador se oculta`);
        continue;
      }
      assert.equal(r.meterVisible, true, `${s.nombre}: indicador visible`);
      assert.equal(r.meterPct, r.cardPct, `${s.nombre}: mismo número en tarjeta e indicador`);
      assert.equal(r.meterPct, `${s.detail.pct} %`, `${s.nombre}: el número es el publicado`);
      assert.equal(r.meterColor, r.cardColor, `${s.nombre}: mismo color en tarjeta e indicador`);
      assert.equal(r.meterNow, r.cardNow, `${s.nombre}: mismo aria-valuenow`);
      assert.equal(r.label, `Contexto usado: ${s.detail.pct} % (estimado)`, `${s.nombre}: aria-label con el valor`);
      assert.equal(r.cardLabel, 'Estimado');
    }
  } finally {
    child.kill();
    try { fs.rmSync(profile, { recursive: true, force: true }); } catch (_) { /* Chromium aún suelta el perfil */ }
  }
}

module.exports = main;
if (require.main === module) main().catch(error => { console.error(error); process.exitCode = 1; });
