// — datos hostiles en los sitios migrados a los helpers de html.ts.
// Chromium real por CDP (mismo arnés que right_cards_ui_test.cjs): un dato con
// <img onerror>, <script>, <svg onload> y comillas debe pintarse como TEXTO y
// no puede crear elementos, atributos on* ni salirse de un atributo.
// Sitios: catalog_sessions (catálogo y sesiones), verification_panel
// (verificaciones y ledger), timeline, command_palette y browser_bar
// (pestañas, origen, tarjetas de error/bloqueo).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const HOSTILE = `<img src=x onerror="window.__pwn=1"><script>window.__pwn=2</script>"'><svg onload="window.__pwn=3">`;

module.exports = async function seg017HtmlUi() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-seg017-'));
  const executable = process.env.DEVAGENTS_TEST_BROWSER || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const html = path.join(profile, 'seg017.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map();
  child.stderr.on('data', d => { stderr += d; });
  const fail = e => { for (const r of pending.values()) { clearTimeout(r.timer); r.reject(e); } pending.clear(); };
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
    const bundle = fs.readFileSync(path.join(__dirname, '../shell/webui/dist/seg017.test.js'), 'utf8');
    await evaluate(`(0, eval)(${JSON.stringify(bundle)}); window.Seg = Seg; true`);

    // Los helpers: escape por defecto, SafeHtml pasa, listas se concatenan.
    const unit = await evaluate(`(() => {
      const H = ${JSON.stringify(HOSTILE)};
      const a = Seg.html\`<b>\${H}</b>\`.value;
      const b = Seg.html\`<i>\${Seg.html\`<u>\${H}</u>\`}</i>\`.value;
      const c = Seg.html\`\${[Seg.html\`<p>\${H}</p>\`, Seg.html\`<p>2</p>\`]}\`.value;
      const d = Seg.html\`\${Seg.raw('<hr>')}\${1}\${null}\`.value;
      return {a, b, c, d};
    })()`);
    assert(!unit.a.includes('<img') && !unit.a.includes('<script') && unit.a.includes('&lt;img'), 'html`` escapa el dato');
    assert(unit.b.includes('<u>') && !unit.b.includes('<img'), 'SafeHtml anidado no se vuelve a escapar y su dato sí');
    assert.equal((unit.c.match(/<p>/g) || []).length, 2, 'las listas de SafeHtml se concatenan');
    assert.equal(unit.d, '<hr>1', 'raw pasa, número se escapa a texto y null a vacío');

    // Montaje de los cinco sitios con el dato hostil en TODOS sus campos.
    await evaluate(`(() => {
      const H = ${JSON.stringify(HOSTILE)};
      document.body.innerHTML = '<div id="app-shell"></div><div id="c-cat"></div><div id="c-ver"></div><div id="c-tl"></div><div id="browser-surface"></div><div id="beats-app"></div>';
      window.__pwn = undefined;
      const cat = new Seg.CatalogSessionsPanel(document.getElementById('c-cat'));
      cat.setCatalog([{ id: 'm1', name: H, provider: H, isFree: true, contextWindow: H, latencyMs: 1 }]);
      cat.setSessions([{ id: H, title: H, messageCount: H, updatedAt: H, conversationId: H }]);
      const ver = new Seg.VerificationPanel(document.getElementById('c-ver'));
      ver.setVerifications([{ id: 'v1', item: H, verdict: H, evidencePath: H }]);
      ver.setLedger([{ index: H, hash: H, prevHash: H, action: H, model: H }]);
      const tl = new Seg.Timeline(document.getElementById('c-tl'));
      tl.setEvents([{ id: 1, ts: 1, source: H, kind: 'task_failed', payload: { message: H } }]);
      const palette = new Seg.CommandPalette();
      palette.registerCommands([{ id: 'c1', label: H, category: H, shortcut: H, action() {} }]);
      palette.show();
      let push = () => {};
      const bridge = { onPush(cb) { push = cb; }, send: async () => ({}) };
      window.__bar = new Seg.BrowserBar(bridge, () => {});
      const tab = (over) => Object.assign({ id: H, title: H, url: 'http://localhost:3000/', origin: H, trust: H, loading: false, ready: false, can_back: false, can_forward: false, error: null, blocked: null }, over);
      const state = (t) => ({ open: true, full: false, ready: true, bar_css: 40, panel_px: 400, active: t.id, status: '', status_error: false, tabs: [t], approvals: [], control_state: 'user_control' });
      window.__push = push; window.__state = state; window.__tab = tab;
      push('browser.state', state(tab({ error: { code: 1, detail: H, reason: H } })));
      return true;
    })()`);
    await evaluate('new Promise(r=>setTimeout(r,120))');

    const audit = async (label, selector) => evaluate(`(() => {
      const H = ${JSON.stringify(HOSTILE)};
      const root = document.querySelector(${JSON.stringify(selector)});
      const bad = [];
      for (const el of root.querySelectorAll('*')) {
        if (el.tagName === 'IMG' || el.tagName === 'SCRIPT') bad.push('elemento ' + el.tagName);
        for (const a of el.attributes) if (/^on/i.test(a.name)) bad.push('atributo ' + a.name + ' en ' + el.tagName);
      }
      return { bad, pwn: window.__pwn === undefined, shown: root.textContent.includes('<img src=x onerror='), text: root.textContent.length };
    })()`);

    const sites = [
      ['catalog_sessions', '#c-cat'], ['verification_panel', '#c-ver'], ['timeline', '#c-tl'],
      ['command_palette', '#command-palette-overlay'], ['browser_bar (tarjeta de error)', '#browser-surface'],
    ];
    for (const [label, selector] of sites) {
      const r = await audit(label, selector);
      assert.deepEqual(r.bad, [], `${label}: el dato hostil no crea elementos ni atributos on*`);
      assert.equal(r.pwn, true, `${label}: no se ejecutó código del dato`);
      assert.equal(r.shown, true, `${label}: el dato se muestra literal como texto`);
    }

    // Atributos: el dato hostil queda ÍNTEGRO dentro de su atributo (sin romperlo).
    const attrs = await evaluate(`(() => ({
      replayId: document.querySelector('#c-cat .btn-replay').getAttribute('data-id'),
      replayConv: document.querySelector('#c-cat .btn-replay').getAttribute('data-conversation'),
      tabAttr: document.querySelector('#bb-strip [role="tab"]').getAttribute('data-tab'),
      trustAttr: document.querySelector('#bb-strip .btab__mark').getAttribute('data-trust'),
      closeAttr: document.querySelector('#bb-strip .btab__x').getAttribute('data-close'),
      tabCount: document.querySelectorAll('#bb-strip [role="tab"]').length,
    }))()`);
    for (const [name, value] of Object.entries({ replayId: attrs.replayId, replayConv: attrs.replayConv, tabAttr: attrs.tabAttr, trustAttr: attrs.trustAttr, closeAttr: attrs.closeAttr })) {
      assert.equal(value, HOSTILE, `atributo ${name} conserva el dato literal`);
    }
    assert.equal(attrs.tabCount, 1);

    // Origen, nav y tarjetas restantes de la barra (bloqueo, espera) con el mismo dato.
    for (const [label, expr] of [
      ['bloqueo', `window.__push('browser.state', window.__state(window.__tab({ blocked: { origin: ${JSON.stringify(HOSTILE)}, url: 'http://x/', reason: ${JSON.stringify(HOSTILE)} } })))`],
      ['espera', `window.__push('browser.state', Object.assign(window.__state(window.__tab({})), { approvals: [{ id: 'r1', origin: ${JSON.stringify(HOSTILE)}, source: 'agent' }] }))`],
    ]) {
      await evaluate(expr + '; true');
      await evaluate('new Promise(r=>setTimeout(r,60))');
      const r = await audit(label, '#browser-surface');
      assert.deepEqual(r.bad, [], `browser_bar ${label}: sin elementos ni on*`);
      assert.equal(r.pwn, true, `browser_bar ${label}: sin ejecución`);
    }

    // r2 · paintEngineOutput: el sumidero no depende del productor. Llega una
    // traza hostil como `string` crudo por el evento devagents:engine-output
    // (contrato roto / tipo equivocado) y aun así no puede crear elementos ni
    // atributos on*: asSafeHtml la escapa. Antes del cambio, ${traza} iba
    // directo a innerHTML y el <img onerror> se creaba.
    await evaluate(`(() => {
      const H = ${JSON.stringify(HOSTILE)};
      document.body.innerHTML = '<div id="engine-output"></div>';
      window.__pwn = undefined;
      new Seg.ViewRouter({});
      document.dispatchEvent(new CustomEvent('devagents:engine-output', { detail: { stream: H, traza: H, problemas: [H] } }));
      return true;
    })()`);
    await evaluate('new Promise(r=>setTimeout(r,60))');
    const sink = await audit('paintEngineOutput', '#engine-output');
    assert.deepEqual(sink.bad, [], 'paintEngineOutput: la traza hostil no crea elementos ni atributos on*');
    assert.equal(sink.pwn, true, 'paintEngineOutput: no se ejecutó código de la traza');
    assert.equal(sink.shown, true, 'paintEngineOutput: la traza hostil se muestra literal como texto');

    // Y el camino seguro conserva el marcado: un SafeHtml (html``) del productor
    // sí se inserta como HTML, sin volver a escaparlo.
    await evaluate(`(() => {
      document.body.innerHTML = '<div id="engine-output"></div>';
      window.__pwn = undefined;
      new Seg.ViewRouter({});
      const safe = Seg.html\`<div class="row"><span>traza</span></div>\`;
      document.dispatchEvent(new CustomEvent('devagents:engine-output', { detail: { stream: '', traza: safe, problemas: [] } }));
      return true;
    })()`);
    await evaluate('new Promise(r=>setTimeout(r,60))');
    const kept = await evaluate(`document.querySelector('#engine-output .row span') ? document.querySelector('#engine-output .row span').textContent : null`);
    assert.equal(kept, 'traza', 'paintEngineOutput: el SafeHtml del productor conserva su marcado');

    console.log('PASS CK-SEG-017: dato hostil (<img onerror>, <script>, <svg onload>, comillas) pintado como texto en catalog_sessions, verification_panel, timeline, command_palette, browser_bar y paintEngineOutput; atributos íntegros; helpers html/raw/joinHtml/setHtml/asSafeHtml');
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); } catch (_) { /* ya cerrado */ }
    if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
    fail(Error('Browser closed'));
    try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 }); } catch (_) { /* perfil aún en uso */ }
  }
};

if (require.main === module) module.exports().catch(error => { console.error(error); process.exitCode = 1; });
