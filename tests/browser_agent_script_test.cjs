// T6 (13-nov-2026,) — prueba determinista del script de página del
// agente (shell/host/browser_agent_script.hpp). Arnés: Chromium real por CDP
// (mismo patrón que tests/conversation_ui_test.cjs). Carga una página
// local fija (tests/browser_agent_script_fixture.html) con un viewport fijo de
// 800x600, evalúa el script EXACTO del host en un mundo aislado
// (Page.createIsolatedWorld, como browser_panel.cpp) y despacha la entrada real
// por CDP `Input`, igual que el host. Comprueba con resultados exactos:
//   snapshot, find, click, type (con el rechazo de campos sensibles), key,
//   scroll, referencias caducadas, aislamiento del registro de referencias, y
//   las operaciones de T6: wait, formcheck/checkprep/selectopt (fill_form),
//   shotprep + captura (screenshot), hover y drag por coordenadas.
// BROWSER_AGENT_SCRIPT permite apuntar a otra copia del .hpp (la de main = rojo).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('./browser_resolver.cjs');

function scriptFromHeader(file, marker = 'Script = R"js(') {
  const source = fs.readFileSync(file, 'utf8');
  const at = source.indexOf(marker);
  if (at < 0) return null;
  const start = source.indexOf('R"js(', at);
  const end = source.indexOf(')js"', start);
  if (start < 0 || end < 0) throw new Error('No se encuentra R"js(...)js" en ' + file);
  return source.slice(start + 5, end);
}

module.exports = async function browserAgentScript() {
  const header = process.env.BROWSER_AGENT_SCRIPT || path.join(__dirname, '../shell/host/browser_agent_script.hpp');
  const script = scriptFromHeader(header);
  // T6: script de browser_debug_js (otro mundo aislado). En main no existe.
  const debugScript = scriptFromHeader(header, 'DebugScript = R"js(');
  const fixture = pathToFileURL(path.join(__dirname, 'browser_agent_script_fixture.html')).href;
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'devagents-agent-script-'));
  const child = spawn(resolveBrowser(), ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', '--hide-scrollbars', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session;
  const pending = new Map();
  const events = [];
  let stderr = '';
  child.stderr.on('data', data => { stderr += data; });
  const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      const request = pending.get(message.id);
      if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
      else if (message.method) events.push(message);
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 30000);
      pending.set(id, { resolve, reject, timer });
      child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }
  // Mundo principal: lo que ve la propia página.
  async function page(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (result.exceptionDetails) throw new Error('page: ' + JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  let world = 0;
  // Misma forma que AgentEval en browser_panel.cpp: (script)("op", args).
  async function op(name, args = {}) {
    const expression = '(' + script + ')(' + JSON.stringify(name) + ',' + JSON.stringify(args) + ')';
    const result = await send('Runtime.evaluate', { expression, contextId: world, returnByValue: true, awaitPromise: true, timeout: 4000 });
    if (result.exceptionDetails) throw new Error('script: ' + JSON.stringify(result.exceptionDetails));
    return JSON.parse(result.result.value);
  }
  const mouse = async (type, x, y, extra = {}) => send('Input.dispatchMouseEvent', { type, x, y, button: 'none', buttons: 0, ...extra });
  async function click(x, y) {
    await mouse('mouseMoved', x, y);
    await mouse('mousePressed', x, y, { button: 'left', buttons: 1, clickCount: 1 });
    await mouse('mouseReleased', x, y, { button: 'left', buttons: 0, clickCount: 1 });
  }

  const failures = [];
  let total = 0;
  function check(name, ok, detail) {
    total += 1;
    if (ok) console.log(`  ok: ${name}`);
    else { failures.push(name); console.error(`  FAIL: ${name}${detail === undefined ? '' : ' -> ' + JSON.stringify(detail)}`); }
  }
  const guard = async (name, fn) => {
    try { await fn(); } catch (e) { check(name + ' (sin excepción)', false, String(e.message || e).slice(0, 400)); }
  };
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

  try {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Emulation.setDeviceMetricsOverride', { width: 800, height: 600, deviceScaleFactor: 1, mobile: false });
    await send('Page.enable');
    // Lo mismo que activa el host en cada pestaña para browser_console y
    // browser_network (browser_panel.cpp, ListenAgentLog).
    await send('Runtime.enable');
    await send('Network.enable');
    await send('Page.navigate', { url: fixture });
    {
      // Esperar a que el documento pedido sustituya al about:blank inicial: con
      // solo readyState, la navegación podía llegar después y borrar el estado
      // ya montado (rojos intermitentes del 13 y 14-nov, update_ui y right_cards).
      const deadline = Date.now() + 10000;
      const ready = () => page("location.href!=='about:blank' && document.readyState==='complete' && document.head!==null")
        .catch(error => { if (/context was destroyed|Cannot find context/i.test(error.message)) return false; throw error; });
      while (!await ready()) {
        if (Date.now() >= deadline) throw new Error('Timeout esperando el documento de la prueba');
        await new Promise(resolve => setTimeout(resolve, 25));
      }
    }
    const tree = await send('Page.getFrameTree');
    world = (await send('Page.createIsolatedWorld', { frameId: tree.frameTree.frame.id, worldName: 'devagents-agent' })).executionContextId;

    let snap;
    await guard('snapshot', async () => {
      snap = await op('snapshot');
      const r = snap.result;
      check('snapshot ok', snap.ok === true, snap);
      check('snapshot_id con formato s1-xxxxxx', /^s1-[a-z0-9]{1,6}$/.test(r.snapshot_id), r.snapshot_id);
      check('snapshot cabecera exacta', same({ view_revision: r.view_revision, title: r.title, viewport_w: r.viewport_w, viewport_h: r.viewport_h, scroll_x: r.scroll_x, scroll_y: r.scroll_y, page_h: r.page_h, truncated: r.truncated, url: r.url },
        { view_revision: 1, title: 'Banco del agente', viewport_w: 800, viewport_h: 600, scroll_x: 0, scroll_y: 0, page_h: 3000, truncated: false, url: fixture }), r);
      const expected = [
        { ref: 'e0', role: 'heading', name: 'Formulario de prueba', x: 10, y: 10, w: 300, h: 30 },
        { ref: 'e1', role: 'heading', name: 'Cargando', x: 400, y: 10, w: 200, h: 30 },
        { ref: 'e2', role: 'textbox', name: 'Nombre', x: 10, y: 60, w: 200, h: 24, value: '' },
        { ref: 'e3', role: 'textbox', name: 'Clave', x: 10, y: 100, w: 200, h: 24, sensitive: true },
        { ref: 'e4', role: 'textbox', name: 'Tarjeta', x: 10, y: 140, w: 200, h: 24, sensitive: true },
        { ref: 'e5', role: 'checkbox', name: 'Acepto', x: 10, y: 180, w: 20, h: 20, checked: false },
        { ref: 'e6', role: 'radio', name: 'Basico', x: 10, y: 210, w: 20, h: 20, checked: true },
        { ref: 'e7', role: 'radio', name: 'Pro', x: 40, y: 210, w: 20, h: 20, checked: false },
        { ref: 'e8', role: 'combobox', name: 'Pais', x: 10, y: 240, w: 120, h: 24, value: 'Espana', options: [{ ref: 'o0', label: 'Espana', selected: true }, { ref: 'o1', label: 'Mexico', selected: false }] },
        { ref: 'e9', role: 'button', name: 'Enviar', x: 10, y: 280, w: 100, h: 30 },
        { ref: 'e10', role: 'button', name: 'Zona', x: 400, y: 60, w: 200, h: 200 },
        { ref: 'e11', role: 'button', name: 'Tapado', x: 10, y: 330, w: 100, h: 30 },
      ];
      check('snapshot elementos exactos (sin valores de campos sensibles)', same(r.elements, expected), r.elements);
      check('el registro de referencias no es visible para la página', await page('typeof window.__devagents') === 'undefined');
    });

    await guard('find', async () => {
      const f = await op('find', { query: { role: 'button', name: 'Enviar', exact: true } });
      check('find por rol y nombre exactos', f.ok && f.result.matches.length === 1 && f.result.matches[0].ref === 'e9' && f.result.snapshot_id !== snap.result.snapshot_id, f);
      const t = await op('find', { query: { text: 'Formulario' } });
      check('find por texto', t.ok && same(t.result.matches.map(m => [m.ref, m.name]), [['e0', 'Formulario de prueba']]), t);
      const stale = await op('point', { target: { ref: 'e9', snapshot_id: snap.result.snapshot_id } });
      check('referencia de un snapshot anterior: stale_reference', same(stale, { ok: false, code: 'stale_reference' }), stale);
      snap = await op('snapshot');
    });
    const ref = (r) => ({ ref: r, snapshot_id: snap.result.snapshot_id });

    await guard('click', async () => {
      const p = await op('point', { target: ref('e9') });
      check('point del botón: centro exacto', same(p, { ok: true, result: { x: 60, y: 295, role: 'button', name: 'Enviar', view_revision: 1 } }), p);
      await click(p.result.x, p.result.y);
      check('el clic llega a la página', same(await page('window.log'), ['click']), await page('window.log'));
      const covered = await op('point', { target: ref('e11') });
      check('botón tapado por otra capa: occluded', same(covered, { ok: false, code: 'occluded' }), covered);
    });

    await guard('wait', async () => {
      const text = await op('wait', { condition: 'text', target: ref('e9'), expected: 'Enviado', budget: 3000 });
      check('wait text se cumple tras el cambio', text.ok && text.result.met === true && text.result.condition === 'text', text);
      const hidden = await op('wait', { condition: 'hidden', target: ref('e1'), budget: 3000 });
      check('wait hidden se cumple al ocultarse', hidden.ok && hidden.result.met === true, hidden);
      const load = await op('wait', { condition: 'load', budget: 0 });
      check('wait load', load.ok && load.result.met === true, load);
      const url = await op('wait', { condition: 'url', expected: 'browser_agent_script_fixture.html', budget: 0 });
      check('wait url', url.ok && url.result.met === true, url);
      const t0 = Date.now();
      const never = await op('wait', { condition: 'text', target: ref('e9'), expected: 'Nunca', budget: 300 });
      const spent = Date.now() - t0;
      check('wait no cumplido devuelve met=false al agotar su tramo', never.ok && never.result.met === false && spent >= 300 && spent < 2500, { never, spent });
      const t1 = Date.now();
      const fixed = await op('wait', { condition: 'time', budget: 250 });
      const waited = Date.now() - t1;
      check('wait time se cumple al agotar su tramo', fixed.ok && fixed.result.met === true && fixed.result.condition === 'time' && waited >= 250 && waited < 2000, { fixed, waited });
      const secret = await op('wait', { condition: 'text', target: ref('e3'), expected: 'x', budget: 0 });
      check('wait text no lee campos sensibles', same(secret, { ok: false, code: 'sensitive_field_denied' }), secret);
    });

    await guard('type', async () => {
      const prep = await op('typeprep', { target: ref('e2'), mode: 'replace', empty: false });
      check('typeprep en campo normal enfoca', same(prep, { ok: true, result: { role: 'textbox', name: 'Nombre', focused: true } }), prep);
      await send('Input.insertText', { text: 'Ana' });
      check('el texto llega al campo', await page("document.getElementById('nombre').value") === 'Ana');
      const pass = await op('typeprep', { target: ref('e3'), mode: 'replace', empty: false });
      check('typeprep en contraseña: sensitive_field_denied', same(pass, { ok: false, code: 'sensitive_field_denied' }), pass);
      const card = await op('typeprep', { target: ref('e4'), mode: 'append', empty: false });
      check('typeprep en tarjeta (cc-number): sensitive_field_denied', same(card, { ok: false, code: 'sensitive_field_denied' }), card);
      const button = await op('typeprep', { target: ref('e9'), mode: 'replace', empty: false });
      check('typeprep en botón: not_editable', same(button, { ok: false, code: 'not_editable' }), button);
      const text = await op('text', { target: ref('e3') });
      check('text de un campo sensible: sensitive_field_denied', same(text, { ok: false, code: 'sensitive_field_denied' }), text);
    });

    await guard('key', async () => {
      const prep = await op('keyprep', { target: ref('e2') });
      check('keyprep en campo normal', same(prep, { ok: true, result: { sensitive: false, role: 'textbox', name: 'Nombre' } }), prep);
      const common = { key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13, nativeVirtualKeyCode: 13, modifiers: 0 };
      await send('Input.dispatchKeyEvent', { type: 'keyDown', text: '\r', ...common });
      await send('Input.dispatchKeyEvent', { type: 'keyUp', ...common });
      check('Enter llega con el valor escrito', (await page('window.log')).includes('enter:Ana'), await page('window.log'));
      const secret = await op('keyprep', { target: ref('e3') });
      check('keyprep sobre contraseña la marca sensible (el host niega teclas imprimibles)', secret.ok && secret.result.sensitive === true, secret);
    });

    // Auditoría B-1: la página no puede lavar un campo secreto cambiando
    // type=password a text entre llamadas. Sin nuevo snapshot (los refs
    // vivos son los del último collect): el ya marcado sigue sensible en
    // text/typeprep, y un password recién mutado también, localizado por
    // coordenadas.
    await guard('sensitive sticky', async () => {
      const sid = snap.result.snapshot_id;
      const p0 = await op('point', { target: { ref: 'e2', snapshot_id: sid } });
      const rev = p0.ok ? p0.result.view_revision : snap.result.view_revision;
      await page("document.getElementById('clave').value = 'super-secreto'; document.getElementById('clave').setAttribute('type', 'text'); 1");
      await page("(() => { const i = document.createElement('input'); i.id = 'b1nueva'; i.type = 'password'; i.setAttribute('aria-label', 'PinB1'); i.value = 'secreto-b1'; i.style.cssText = 'position:absolute;left:10px;top:400px;width:200px;height:24px;z-index:99'; document.body.append(i); setTimeout(() => { i.setAttribute('type', 'text'); }, 0); })(); 1");
      await new Promise((r) => setTimeout(r, 80));
      const t2 = await op('text', { target: { ref: 'e3', snapshot_id: sid } });
      check('text del password mutado a text: sensitive_field_denied', same(t2, { ok: false, code: 'sensitive_field_denied' }), t2);
      const tp = await op('typeprep', { target: { ref: 'e3', snapshot_id: sid }, mode: 'replace', empty: false });
      check('typeprep del password mutado a text: sensitive_field_denied', same(tp, { ok: false, code: 'sensitive_field_denied' }), tp);
      const tn = await op('text', { target: { x: 20, y: 410, view_revision: rev } });
      check('text del password nuevo mutado a text: sensitive_field_denied', same(tn, { ok: false, code: 'sensitive_field_denied' }), tn);
      const tpn = await op('typeprep', { target: { x: 20, y: 410, view_revision: rev }, mode: 'replace', empty: false });
      check('typeprep del password nuevo mutado a text: sensitive_field_denied', same(tpn, { ok: false, code: 'sensitive_field_denied' }), tpn);
      // Restaura para las guardas siguientes.
      await page("document.getElementById('clave').setAttribute('type', 'password'); document.getElementById('b1nueva').remove(); 1");
    });

    await guard('fill_form', async () => {
      const bad = await op('formcheck', { fields: [{ target: ref('e2'), kind: 'text', value: 'x' }, { target: ref('e3'), kind: 'text', value: 'x' }] });
      check('formcheck con un campo de contraseña: sensitive_field_denied antes de escribir nada', same(bad, { ok: false, code: 'sensitive_field_denied' }) && await page("document.getElementById('nombre').value") === 'Ana', bad);
      const wrongKind = await op('formcheck', { fields: [{ target: ref('e9'), kind: 'checkbox', value: true }] });
      check('formcheck con un botón como casilla: not_editable', same(wrongKind, { ok: false, code: 'not_editable' }), wrongKind);
      const badOption = await op('formcheck', { fields: [{ target: ref('e8'), kind: 'select', value: { option_ref: 'o7' } }] });
      check('formcheck con opción inexistente: element_not_found', same(badOption, { ok: false, code: 'element_not_found' }), badOption);
      const good = await op('formcheck', { fields: [{ target: ref('e2'), kind: 'text', value: 'x' }, { target: ref('e5'), kind: 'checkbox', value: true }, { target: ref('e8'), kind: 'select', value: { option_ref: 'o1' } }] });
      check('formcheck válido', same(good, { ok: true, result: { fields: 3 } }), good);
      const box = await op('checkprep', { target: ref('e5'), kind: 'checkbox', value: true });
      check('checkprep casilla sin marcar: punto exacto', same(box, { ok: true, result: { changed: true, x: 20, y: 190 } }), box);
      await click(box.result.x, box.result.y);
      const again = await op('checkprep', { target: ref('e5'), kind: 'checkbox', value: true });
      check('tras el clic la casilla queda marcada', same(again, { ok: true, result: { changed: false, checked: true } }), again);
      const pro = await op('checkprep', { target: ref('e7'), kind: 'radio', value: true });
      check('checkprep radio', pro.ok && pro.result.changed === true, pro);
      await click(pro.result.x, pro.result.y);
      check('el radio Pro queda marcado', await page("document.getElementById('pro').checked && !document.getElementById('basico').checked") === true);
      const off = await op('checkprep', { target: ref('e7'), kind: 'radio', value: false });
      check('desmarcar un radio: not_interactable', same(off, { ok: false, code: 'not_interactable' }), off);
      const sel = await op('selectopt', { target: ref('e8'), kind: 'select', value: { option_ref: 'o1' } });
      check('selectopt elige la opción', same(sel, { ok: true, result: { selected: 'Mexico', index: 1 } }), sel);
      check('la página recibe change con el valor nuevo', (await page('window.log')).includes('change:Mexico') && await page("document.getElementById('pais').value") === 'Mexico', await page('window.log'));
    });

    await guard('screenshot', async () => {
      // El clic en el botón tapado centró la vista y typeprep la devolvió a 0: la
      // revisión cuenta esos desplazamientos reales.
      const rev = (await op('state', { ms: 0 })).result.view_revision;
      const shot = await op('shotprep', { target: ref('e9') });
      check('shotprep de un elemento: recorte exacto', same(shot, { ok: true, result: { x: 10, y: 280, width: 100, height: 30, view_revision: rev } }), shot);
      const capture = await send('Page.captureScreenshot', { format: 'png', clip: { ...shot.result, scale: 1 }, captureBeyondViewport: false });
      const png = Buffer.from(capture.data, 'base64');
      check('la captura es un PNG del tamaño del recorte', png.subarray(1, 4).toString() === 'PNG' && png.readUInt32BE(16) === 100 && png.readUInt32BE(20) === 30, [png.readUInt32BE(16), png.readUInt32BE(20)]);
      const rect = await op('shotprep', { rect: { x: 0, y: 0, width: 50, height: 40 }, view_revision: rev });
      check('shotprep de un rectángulo', same(rect, { ok: true, result: { x: 0, y: 0, width: 50, height: 40, view_revision: rev } }), rect);
      const staleRect = await op('shotprep', { rect: { x: 0, y: 0, width: 50, height: 40 }, view_revision: 99 });
      check('rectángulo de otra vista: stale_view', same(staleRect, { ok: false, code: 'stale_view' }), staleRect);
    });

    await guard('hover y drag', async () => {
      const p = await op('point', { target: ref('e10') });
      check('point de la zona', same(p.result && [p.result.x, p.result.y], [500, 160]), p);
      await mouse('mouseMoved', p.result.x, p.result.y);
      const settled = await op('state', { ms: 0 });
      check('hover: la página recibe mouseenter', (await page('window.log')).includes('hover') && settled.ok, await page('window.log'));
      const to = await op('point', { target: { x: 580, y: 200, view_revision: settled.result.view_revision } });
      check('point por coordenadas de la vista actual', same(to, { ok: true, result: { x: 580, y: 200, role: 'button', name: 'Zona', view_revision: settled.result.view_revision } }), to);
      await mouse('mousePressed', 500, 160, { button: 'left', buttons: 1, clickCount: 1 });
      for (let i = 1; i <= 4; i += 1) await mouse('mouseMoved', 500 + 20 * i, 160 + 10 * i, { button: 'left', buttons: 1 });
      await mouse('mouseReleased', 580, 200, { button: 'left', buttons: 0, clickCount: 1 });
      check('drag: la página ve el arrastre completo', (await page('window.log')).includes('drag:80,40'), await page('window.log'));
    });

    await guard('scroll', async () => {
      const s = await op('scroll', { dx: 0, dy: 300 });
      check('scroll desplaza exactamente 300 px', s.ok && s.result.moved_y === 300 && s.result.scroll_y === 300 && s.result.view_revision > 1, s);
      const stale = await op('point', { target: { x: 60, y: 10, view_revision: 1 } });
      check('coordenadas de una vista anterior: stale_view', same(stale, { ok: false, code: 'stale_view' }), stale);
      const unknown = await op('desconocida');
      check('operación desconocida: backend_unsupported', same(unknown, { ok: false, code: 'backend_unsupported' }), unknown);
    });

    // T6: forma real de los eventos y parámetros CDP que usa el host para
    // browser_console, browser_network, browser_viewport, browser_color_scheme
    // y browser_screenshot. Los JSON literales son los que comprueba
    // test_browser_panel_agent.cpp para ViewportParams y ColorSchemeParams.
    await guard('consola y red', async () => {
      await page("console.error('fallo', 7, true); setTimeout(() => { throw new Error('boom'); }, 0); 1");
      await new Promise(r => setTimeout(r, 300));
      const logged = events.find(e => e.method === 'Runtime.consoleAPICalled' && e.params.type === 'error');
      check('consoleAPICalled trae type, args con value y stackTrace', !!logged && logged.params.args.map(a => a.value).join(' ') === 'fallo 7 true' && Array.isArray(logged.params.stackTrace.callFrames), logged && logged.params);
      const thrown = events.find(e => e.method === 'Runtime.exceptionThrown');
      check('exceptionThrown trae exceptionDetails.exception.description', !!thrown && /boom/.test(thrown.params.exceptionDetails.exception.description), thrown && thrown.params);
      const doc = events.find(e => e.method === 'Network.requestWillBeSent' && e.params.request.url === fixture);
      check('requestWillBeSent trae requestId, request.method, request.url y type', !!doc && doc.params.request.method === 'GET' && doc.params.type === 'Document' && typeof doc.params.requestId === 'string', doc && doc.params);
    });
    await guard('emulación y captura', async () => {
      await send('Emulation.setDeviceMetricsOverride', JSON.parse('{"width":390,"height":844,"deviceScaleFactor":3.00,"mobile":true,"screenOrientation":{"type":"portraitPrimary","angle":0}}'));
      check('viewport mobile: pantalla 390x844 a 3x (sin meta viewport la página móvil se maqueta a 980)', same(await page('[screen.width, screen.height, devicePixelRatio, innerWidth]'), [390, 844, 3, 980]), await page('[screen.width, screen.height, devicePixelRatio, innerWidth]'));
      const mobileShot = Buffer.from((await send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })).data, 'base64');
      check('captura de la vista emulada: 1170x2532 px', mobileShot.readUInt32BE(16) === 1170 && mobileShot.readUInt32BE(20) === 2532, [mobileShot.readUInt32BE(16), mobileShot.readUInt32BE(20)]);
      await send('Emulation.setEmulatedMedia', JSON.parse('{"features":[{"name":"prefers-color-scheme","value":"dark"}]}'));
      check('color_scheme dark', await page("matchMedia('(prefers-color-scheme: dark)').matches") === true);
      await send('Emulation.setEmulatedMedia', JSON.parse('{"features":[{"name":"prefers-color-scheme","value":""}]}'));
      check('color_scheme system quita la emulación', await page("matchMedia('(prefers-color-scheme: dark)').matches") === false);
      await send('Emulation.clearDeviceMetricsOverride', JSON.parse('{}'));
      const restored = await page('[innerWidth, devicePixelRatio]');
      check('viewport desktop quita la emulación', restored[0] !== 390 && restored[1] === 1, restored);
    });
    await guard('debug_js', async () => {
      check('existe el script de browser_debug_js', typeof debugScript === 'string');
      const tree = await send('Page.getFrameTree');
      const debugWorld = (await send('Page.createIsolatedWorld', { frameId: tree.frameTree.frame.id, worldName: 'devagents-debug' })).executionContextId;
      const debug = async (code, timeout = 2000) => {
        const reply = await send('Runtime.evaluate', { expression: '(' + debugScript + ')(' + JSON.stringify(code) + ',' + timeout + ')', contextId: debugWorld, returnByValue: true, awaitPromise: true, timeout });
        return reply.result && typeof reply.result.value === 'string' ? JSON.parse(reply.result.value) : { exceptionDetails: !!reply.exceptionDetails };
      };
      const title = await debug('document.title');
      check('debug_js devuelve el valor de la última expresión', same(title, { ok: true, result: { threw: false, type: 'string', value: 'Banco del agente' } }), title);
      const awaited = await debug('new Promise((r) => setTimeout(() => r(42), 10))');
      check('debug_js espera las promesas', awaited.ok && awaited.result.value === '42', awaited);
      const element = await debug("document.getElementById('nombre')");
      check('debug_js describe elementos sin volcarlos', element.ok && element.result.value === '<input#nombre.a>', element);
      for (const [name, code] of [['leer una contraseña', "document.getElementById('clave').value"], ['escribir una tarjeta', "document.getElementById('tarjeta').value = '4111'"], ['seleccionar una contraseña', "document.getElementById('clave').select()"]]) {
        const r = await debug(code);
        check('debug_js no puede ' + name + ': sensitive_field_denied', same(r, { ok: false, code: 'sensitive_field_denied' }), r);
      }
      check('la página sigue sin la tarjeta escrita', await page("document.getElementById('tarjeta').value") === '');
      for (const [name, code, what] of [['abrir un diálogo', "confirm('¿seguro?')", 'window_or_dialog'], ['abrir una ventana', "open('https://example.com')", 'window_or_dialog'], ['crear un <script>', "document.createElement('script')", 'script_injection'], ['poner un atributo on*', "document.body.setAttribute('onclick', 'x()')", 'script_injection'], ['meter HTML crudo', "document.body.innerHTML = '<img src=x onerror=alert(1)>'", 'script_injection'], ['un enlace javascript:', "document.createElement('a').href = 'javascript:alert(1)'", 'script_injection'], ['enviar un formulario', "HTMLFormElement.prototype.submit.call(document.createElement('form'))", 'form_submit']]) {
        const r = await debug(code);
        check('debug_js no puede ' + name + ' (' + what + ')', r.ok && r.result.threw === true && r.result.blocked === what, r);
      }
      const thrown = await debug("throw new Error('mio')");
      check('una excepción del código se devuelve como threw, no como éxito', thrown.ok && thrown.result.threw === true && /mio/.test(thrown.result.value) && !thrown.result.blocked, thrown);
      // Chromium corta la evaluación al llegar al tope y responde con un error
      // de protocolo; el host lo traduce a timeout (AgentDebug).
      const t0 = Date.now();
      const loop = await debug('for (;;) {}', 300).then(r => ({ answered: r }), e => ({ error: String(e.message) }));
      const spent = Date.now() - t0;
      check('un bucle infinito lo corta el tope de tiempo', /Internal error/.test(loop.error || '') && spent >= 300 && spent < 3000, { loop, spent });
      // Una promesa que nunca se resuelve: Runtime.evaluate no la corta; la
      // corta el propio script con el mismo tope y responde timeout.
      const t1 = Date.now();
      const hang = await debug('new Promise(() => {})', 300);
      const waited = Date.now() - t1;
      check('una promesa que nunca acaba termina en timeout con el tope', same(hang, { ok: false, code: 'timeout' }) && waited >= 280 && waited < 3000, { hang, waited });
      // T12 M1: el campo sensible lo es por identidad y por todas las vías.
      await page("document.getElementById('clave').value = 'secreto-1'; (() => { const f = document.createElement('form'); f.id = 'f12'; const p = document.createElement('input'); p.type = 'password'; p.name = 'pin'; p.id = 'pin12'; p.setAttribute('value', 'inicial-2'); p.value = 'secreto-2'; f.append(p); const n = document.createElement('input'); n.name = 'usuario'; n.value = 'ana'; f.append(n); document.body.append(f); localStorage.setItem('token', 'secreto-3'); })(); 1");
      for (const [name, code] of [
        ['leerla tras setAttribute type=text', "const c = document.getElementById('clave'); c.setAttribute('type', 'text'); c.value"],
        ['leerla tras el.type = text', "const c = document.getElementById('clave'); c.type = 'text'; c.value"],
        ['leerla tras quitar el atributo type', "const c = document.getElementById('pin12'); c.removeAttribute('type'); c.value"],
        ['leerla con FormData', "new FormData(document.getElementById('f12')).get('pin')"],
        ['leer su atributo value', "document.getElementById('pin12').getAttribute('value')"],
        ['leer su atributo value por attributes', "document.getElementById('pin12').attributes.value.value"],
        ['clonarla para leer la copia', "const k = document.getElementById('pin12').cloneNode(); k.type = 'text'; k.value"],
        ['serializar el formulario', "document.getElementById('f12').outerHTML"],
        ['usar el getter de otro marco', "const fr = document.getElementById('marco12'); Object.getOwnPropertyDescriptor((fr ? fr.contentWindow : frames[0]).HTMLInputElement.prototype, 'value').get.call(document.getElementById('clave'))"],
        ['usar el constructor del prototipo', "const N = Object.getPrototypeOf(new FormData()).constructor; new N(document.getElementById('f12')).get('pin')"],
      ]) {
        await page("document.getElementById('clave').setAttribute('type', 'password'); document.getElementById('pin12').setAttribute('type', 'password'); 1");
        if (name === 'usar el getter de otro marco') await page("(() => { if (!document.getElementById('marco12')) { const fr = document.createElement('iframe'); fr.id = 'marco12'; document.body.append(fr); } })(); 1");
        const r = await debug(code);
        const denied = same(r, { ok: false, code: 'sensitive_field_denied' }) || (r.ok && r.result.threw === true && r.result.blocked === 'script_injection');
        check('debug_js no puede ' + name + ' (T12 M1)', denied && !JSON.stringify(r).includes('secreto'), r);
      }
      // T12B M-2: un FormData creado en el mundo de la página (antes de que su
      // campo fuera sensible) tampoco se puede leer ni serializar: el
      // constructor nativo ya no se alcanza y las vías de envío comparan el
      // valor con el getter nativo.
      await debug("(() => { const f = document.createElement('form'); f.id = 'fser'; const i = document.createElement('input'); i.name = 'token'; i.value = 'secreto-9'; f.append(i); document.body.append(f); globalThis.__fdser = new FormData(f); i.type = 'password'; return 1; })()");
      for (const [name, code] of [
        ['leerlo con get', "globalThis.__fdser.get('token')"],
        ['leerlo con getAll', "globalThis.__fdser.getAll('token')"],
        ['iterarlo con entries', "Array.from(globalThis.__fdser.entries())"],
        ['iterarlo con values', "Array.from(globalThis.__fdser.values())"],
        ['iterarlo con forEach', "globalThis.__fdser.forEach(() => {})"],
        ['consultarlo con has', "globalThis.__fdser.has('token')"],
        ['iterarlo con Symbol.iterator', "Array.from(globalThis.__fdser)"],
        ['serializarlo con Response', "new Response(globalThis.__fdser).text()"],
        ['serializarlo con Request', "new Request('http://127.0.0.1/x', { method: 'POST', body: globalThis.__fdser })"],
        ['enviarlo con fetch', "fetch('http://127.0.0.1/x', { method: 'POST', body: globalThis.__fdser })"],
        ['enviarlo con XMLHttpRequest', "(() => { const x = new XMLHttpRequest(); x.open('POST', 'http://127.0.0.1/x'); x.send(globalThis.__fdser); })()"],
        ['enviarlo con sendBeacon', "navigator.sendBeacon('http://127.0.0.1/x', globalThis.__fdser)"],
      ]) {
        const r = await debug(code);
        check('debug_js no puede ' + name + ' (T12B M-2)', same(r, { ok: false, code: 'sensitive_field_denied' }) && !JSON.stringify(r).includes('secreto'), r);
      }
      await debug("document.getElementById('fser').remove(); 1");
      const detached = await debug("new Response(globalThis.__fdser).text()");
      check('FormData sensible sigue bloqueado después de retirar el formulario (T12B M-2)', same(detached, { ok: false, code: 'sensitive_field_denied' }), detached);
      await debug("globalThis.__fdser = undefined; 1");
      // Frames: aunque llegue por frames[0], el marco del mismo origen tiene los cierres.
      const viaFrames = await debug("Object.getOwnPropertyDescriptor(frames[0].HTMLInputElement.prototype, 'value').get.call(document.getElementById('clave'))");
      check('debug_js no puede leer la contraseña con el getter de frames[0] (T12 M1)', same(viaFrames, { ok: false, code: 'sensitive_field_denied' }), viaFrames);
      // La propia página pasa a texto una contraseña que nunca vio debug_js
      // («mostrar contraseña») entre dos llamadas: el observador la marcó.
      await page("(() => { const v = document.createElement('input'); v.type = 'password'; v.id = 'ver12'; document.body.append(v); v.value = 'secreto-4'; setTimeout(() => { v.type = 'text'; }, 0); })(); 1");
      await new Promise(r => setTimeout(r, 50));
      const shown = await debug("document.getElementById('ver12').value");
      check('debug_js no lee una contraseña que la página pasó a texto entre llamadas (T12 M1)', same(shown, { ok: false, code: 'sensitive_field_denied' }), shown);
      for (const [name, code] of [['leer document.cookie', 'document.cookie'], ['escribir document.cookie', "document.cookie = 'a=b'"], ['leer localStorage', "localStorage.getItem('token')"], ['leer sessionStorage', 'sessionStorage.length'], ['abrir indexedDB', "indexedDB.open('x')"]]) {
        const r = await debug(code);
        check('debug_js no puede ' + name + ' (T12 M1: storage_denied)', r.ok && r.result.threw === true && r.result.blocked === 'storage_denied' && !JSON.stringify(r).includes('secreto'), r);
      }
      const plain = await debug("new FormData(document.createElement('form')).has('x') === false && document.getElementById('nombre').getAttribute('aria-label')");
      check('lo no sensible sigue leyéndose (FormData vacío, atributos normales)', plain.ok && plain.result.value === 'Nombre', plain);
      await page("document.getElementById('clave').setAttribute('type', 'password'); document.getElementById('clave').value = ''; document.getElementById('f12').remove(); document.getElementById('ver12').remove(); document.getElementById('marco12').remove(); localStorage.clear(); 1");
      check('los cierres del mundo de depuración no tocan la página', await page("Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').configurable === true && typeof window.__devagentsDebugGuard === 'undefined' && document.getElementById('clave').value === ''") === true);
      const ref = await op('snapshot');
      check('el mundo del agente sigue funcionando después', ref.ok === true, ref);
    });
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); }
    finally {
      if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
      fail(Error('Browser closed'));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  }
  if (failures.length) {
    console.error(`BROWSER AGENT SCRIPT: ${failures.length} FAIL de ${total}`);
    assert.fail(`browser_agent_script: ${failures.length} comprobaciones fallidas`);
  }
  console.log(`PASS browser_agent_script: ${total} comprobaciones exactas en Chromium real (snapshot, find, click, type y rechazo de campos sensibles, key, wait, fill_form, screenshot, hover, drag, scroll, referencias caducadas, aislamiento, eventos de consola y red, emulación, captura y debug_js con sus cierres).`);
};

if (require.main === module) module.exports().catch(error => { console.error(error.message || error); process.exitCode = 1; });
