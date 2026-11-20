// Tanda 5 (F0.4,) — actualizador en la cabina. Chromium real por
// CDP (mismo arnés que seg017_html_ui_test.cjs) con los módulos reales
// (components/update_view.ts y design/alerts.ts) y un motor falso:
//  - el interruptor «Buscar actualizaciones una vez al día (no envía datos
//    tuyos)», «Buscar ahora» y el último resultado con su fecha;
//  - el aviso «DevAgents <ver> disponible» con «Ver notas» y «Descargar»;
//  - tras la descarga, «Lista. Se instalará al cerrar…» con la firma y «No instalar»;
//  - «sin publicaciones» y los errores visibles;
//  - un texto de GitHub con <img onerror> se pinta como texto, no como HTML.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('./browser_resolver.cjs');

const root = path.resolve(__dirname, '..');
const HOSTILE = `<img src=x onerror="window.__pwn=1"><script>window.__pwn=2</script>"'><svg onload="window.__pwn=3">`;

module.exports = async function updateUi() {
  fs.mkdirSync(path.join(root, '.zig-cache'), { recursive: true }); // con --cache-dir externa la carpeta no existe
  const profile = fs.mkdtempSync(path.join(root, '.zig-cache/t5-update-ui-'));
  const html = path.join(profile, 'update.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(resolveBrowser(), ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', '--disable-component-update', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
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
    const bundle = fs.readFileSync(path.join(root, 'shell/webui/dist/update_ui.test.js'), 'utf8');
    await evaluate(`(0, eval)(${JSON.stringify(bundle)}); window.Upd = Upd; true`);

    // Motor falso con el contrato de da_update_*_json. Las llamadas quedan en
    // window.__calls; el estado siguiente lo decide cada prueba.
    await evaluate(`(() => {
      const H = ${JSON.stringify(HOSTILE)};
      window.__H = H;
      window.__pwn = undefined;
      window.__calls = [];
      const base = { enabled: true, current: '0.1.0', checked_ms: Date.UTC(2026, 10, 13, 9, 30), staged: null, apply_on_exit: false, download_error: null };
      window.__states = {
        disponible: { ...base, status: 'disponible', detail: 'DevAgents ' + H + ' disponible',
          latest: { version: H, tag: H, notes_url: 'https://github.com/ItlaStudent/DevAgents/releases/tag/v0.2.0', published_at: H } },
        preparada: { ...base, status: 'disponible', detail: 'DevAgents ' + H + ' disponible', apply_on_exit: true,
          latest: { version: H, tag: H, notes_url: null, published_at: H },
          staged: { version: H, path: 'C:\\\\datos\\\\updates\\\\x\\\\setup.exe', sha256: 'a'.repeat(64), signature: 'sin_firma', signature_code: -2146762487 } },
        noInstalar: null,
        sinPublicaciones: { ...base, status: 'sin_publicaciones', detail: 'Todavía no hay versiones publicadas.', latest: null },
        error: { ...base, status: 'error', detail: 'GitHub respondió con el código 500 ' + H, latest: null },
        desactivado: { ...base, enabled: false, status: 'desactivado', detail: 'La búsqueda diaria de actualizaciones está desactivada.', latest: null },
        descargaFallida: { ...base, status: 'disponible', detail: 'DevAgents 0.2.0 disponible', download_error: 'la descarga no coincide con su huella ' + H,
          latest: { version: '0.2.0', tag: 'v0.2.0', notes_url: null, published_at: '' } },
      };
      window.__states.noInstalar = { ...window.__states.preparada, apply_on_exit: false };
      window.__next = window.__states.disponible;
      const reply = (kind, arg) => { window.__calls.push(arg === undefined ? kind : kind + ':' + arg); return Promise.resolve(window.__next); };
      window.__core = {
        updateState: () => reply('state'),
        updateCheck: (force) => reply('check', force),
        updateDownload: () => { window.__calls.push('download'); window.__next = { ...window.__states.preparada, apply_on_exit: false }; return Promise.resolve(window.__next); },
        updateSetEnabled: (on) => reply('setEnabled', on),
        updateApplyOnExit: (apply, unverified) => { window.__calls.push('apply:' + apply + (unverified ? ':sin_firma_verificable' : '')); window.__next = apply ? window.__states.preparada : window.__states.noInstalar; return Promise.resolve(window.__next); },
        openPath: (url) => { window.__calls.push('open:' + url); return Promise.resolve(true); },
      };
      document.body.innerHTML = '<div id="update-card"></div>';
      window.__ctl = new Upd.UpdateController(window.__core, { raise: Upd.raiseAlert, clear: Upd.clearAlert });
      window.__ctl.attach(document.getElementById('update-card'));
      return true;
    })()`);
    const settle = () => evaluate('new Promise(r=>setTimeout(r,80))');
    // Auditoría de inyección: ningún elemento ni atributo on* creado por el dato.
    const audit = (sel) => evaluate(`(() => {
      const bad = [];
      for (const el of document.querySelectorAll('${sel} *')) {
        if (/^(img|script|svg|iframe|object)$/i.test(el.tagName)) bad.push(el.tagName);
        for (const at of el.attributes) if (/^on/i.test(at.name)) bad.push(el.tagName + '@' + at.name);
      }
      return { bad, pwn: window.__pwn === undefined, text: document.querySelector('${sel}') ? document.querySelector('${sel}').textContent : null };
    })()`);

    // 1) Arranque: la comprobación diaria pide check(false) y pinta «disponible».
    await evaluate('window.__ctl.startup()');
    await settle();
    let calls = await evaluate('window.__calls.slice()');
    assert.deepEqual(calls.slice(0, 2), ['state', 'check:false'], 'arranque: estado y comprobación diaria sin forzar');
    const card = await evaluate(`(() => {
      const c = document.getElementById('update-card');
      const t = document.getElementById('update-enabled');
      return { status: c.dataset.updateStatus, text: c.textContent, toggle: t && t.type === 'checkbox' && t.checked,
        checkNow: !!document.getElementById('update-check-now'), when: document.getElementById('update-checked').textContent,
        download: !!document.getElementById('update-download'), notes: document.getElementById('update-notes') && document.getElementById('update-notes').getAttribute('href') };
    })()`);
    assert.equal(card.status, 'disponible');
    assert(card.text.includes('Buscar actualizaciones una vez al día (no envía datos tuyos)'), 'interruptor con su texto');
    assert.equal(card.toggle, true, 'interruptor activado');
    assert(card.checkNow, 'botón «Buscar ahora»');
    assert(/^Última búsqueda: .*2026/.test(card.when), `último resultado con su fecha: ${card.when}`);
    assert(card.download, 'botón «Descargar» en Ajustes');
    assert.equal(card.notes, 'https://github.com/ItlaStudent/DevAgents/releases/tag/v0.2.0');
    let sink = await audit('#update-card');
    assert.deepEqual(sink.bad, [], 'tarjeta: el texto de GitHub no crea elementos ni atributos on*');
    assert.equal(sink.pwn, true, 'tarjeta: no se ejecutó código');
    assert(sink.text.includes(HOSTILE), 'tarjeta: el texto hostil se ve literal');

    // 2) Aviso de esquina: «DevAgents <ver> disponible», con notas y Descargar.
    const alert = await evaluate(`(() => {
      const row = document.querySelector('[data-alert-id="update"]');
      return row ? { title: row.querySelector('.da-alert-title').textContent, buttons: [...row.querySelectorAll('button')].map(b => b.textContent) } : null;
    })()`);
    assert(alert, 'hay aviso de actualización');
    assert.equal(alert.title, `DevAgents ${HOSTILE} disponible`);
    assert.deepEqual(alert.buttons, ['Ver notas', 'Descargar', 'Entendido']);
    sink = await audit('#devagents-alerts');
    assert.deepEqual(sink.bad, [], 'aviso: el título hostil no crea elementos ni atributos on*');
    assert.equal(sink.pwn, true, 'aviso: no se ejecutó código');
    // «Ver notas» se abre fuera por el host (shell.open).
    await evaluate(`[...document.querySelectorAll('[data-alert-id="update"] button')].find(b => b.textContent === 'Ver notas').click()`);
    await settle();
    calls = await evaluate('window.__calls.slice()');
    assert(calls.includes('open:https://github.com/ItlaStudent/DevAgents/releases/tag/v0.2.0'), 'las notas se abren por shell.open');

    // 3) «Descargar» desde el aviso. T12 M3: sin firma verificable NO se acepta
    //    sola: queda descargada, la tarjeta y el aviso lo dicen y piden el
    //    consentimiento expreso, que llega al motor como tal.
    await evaluate(`[...document.querySelectorAll('[data-alert-id="update"] button')].find(b => b.textContent === 'Descargar').click()`);
    await settle();
    calls = await evaluate('window.__calls.slice()');
    assert.equal(calls[calls.length - 1], 'download', 'sin firma verificable, descargar no acepta instalar');
    const pendingConsent = await evaluate(`(() => {
      const row = document.querySelector('[data-alert-id="update"]');
      const w = document.getElementById('update-unverified');
      return { warn: w && w.textContent, plain: !!document.getElementById('update-apply'), consent: document.getElementById('update-apply-unverified') && document.getElementById('update-apply-unverified').textContent,
        alertTitle: row && row.querySelector('.da-alert-title').textContent, alertButtons: row && [...row.querySelectorAll('button')].map(b => b.textContent) };
    })()`);
    assert(pendingConsent.warn && pendingConsent.warn.includes('Sin firma verificable del editor de DevAgents'), JSON.stringify(pendingConsent));
    assert.equal(pendingConsent.plain, false, 'sin firma verificable no hay «Instalar al cerrar» a secas');
    assert.equal(pendingConsent.consent, 'Instalar al cerrar sin firma verificable');
    assert.equal(pendingConsent.alertTitle, `DevAgents ${HOSTILE} descargada`);
    assert.deepEqual(pendingConsent.alertButtons, ['Instalar al cerrar sin firma verificable', 'Entendido']);
    await evaluate(`document.getElementById('update-apply-unverified').click()`);
    await settle();
    calls = await evaluate('window.__calls.slice()');
    assert.equal(calls[calls.length - 1], 'apply:true:sin_firma_verificable', 'el consentimiento expreso llega al motor');
    const ready = await evaluate(`(() => {
      const st = document.getElementById('update-staged');
      const row = document.querySelector('[data-alert-id="update"]');
      return { staged: st && st.textContent, cancel: !!document.getElementById('update-cancel'),
        alertTitle: row && row.querySelector('.da-alert-title').textContent, alertBody: row && row.querySelector('.da-alert-body').textContent,
        alertButtons: row && [...row.querySelectorAll('button')].map(b => b.textContent) };
    })()`);
    assert(ready.staged.includes('Lista. Se instalará al cerrar DevAgents, cuando no haya órdenes en curso.'), ready.staged);
    assert(ready.staged.includes('Sin firma reconocida'), 'se muestra el estado de la firma');
    assert(ready.cancel, 'botón «No instalar» en Ajustes');
    assert.equal(ready.alertTitle, `DevAgents ${HOSTILE} lista`);
    assert(ready.alertBody.includes('Sin firma reconocida'));
    assert.deepEqual(ready.alertButtons, ['No instalar', 'Entendido']);
    sink = await audit('#update-card');
    assert.deepEqual(sink.bad, []);
    // «No instalar»: el motor lo registra y el aviso desaparece.
    await evaluate(`document.getElementById('update-cancel').click()`);
    await settle();
    calls = await evaluate('window.__calls.slice()');
    assert.equal(calls[calls.length - 1], 'apply:false');
    assert.equal(await evaluate(`!!document.getElementById('update-apply-unverified')`), true, 'se puede volver a aceptar (con el consentimiento expreso)');
    assert.deepEqual(await evaluate('Upd.activeAlertIds()'), [], 'sin consentimiento no queda aviso');

    // 4) Sin publicaciones y error: visibles en Ajustes, no ocultos.
    await evaluate(`window.__next = window.__states.sinPublicaciones; window.__ctl.refresh()`);
    await settle();
    let st = await evaluate(`({ s: document.getElementById('update-card').dataset.updateStatus, t: document.getElementById('update-status-text').textContent })`);
    assert.deepEqual(st, { s: 'sin_publicaciones', t: 'Todavía no hay versiones publicadas.' });
    await evaluate(`window.__next = window.__states.error; window.__ctl.refresh()`);
    await settle();
    st = await evaluate(`({ s: document.getElementById('update-card').dataset.updateStatus, t: document.getElementById('update-status-text').textContent })`);
    assert.equal(st.s, 'error');
    assert(st.t.includes('500') && st.t.includes(HOSTILE), 'el motivo del error se ve literal');
    await evaluate(`window.__next = window.__states.descargaFallida; window.__ctl.refresh()`);
    await settle();
    const dlErr = await evaluate(`document.getElementById('update-download-error').textContent`);
    assert(dlErr.includes('la descarga no coincide con su huella'), dlErr);
    sink = await audit('#update-card');
    assert.deepEqual(sink.bad, []);
    assert.equal(sink.pwn, true);
    // Un fallo del puente también se ve.
    await evaluate(`window.__core.updateState = () => Promise.reject(new Error('El motor no esta disponible')); window.__ctl.refresh()`);
    await settle();
    assert.equal(await evaluate(`document.getElementById('update-bridge-error').textContent`), 'Fallo del actualizador: El motor no esta disponible');

    // 5) Interruptor: lo apaga, «Buscar ahora» queda deshabilitado; encendido, fuerza.
    await evaluate(`window.__next = window.__states.desactivado; { const t = document.getElementById('update-enabled'); t.checked = false; t.dispatchEvent(new Event('change')); }`);
    await settle();
    calls = await evaluate('window.__calls.slice()');
    assert.equal(calls[calls.length - 1], 'setEnabled:false');
    st = await evaluate(`({ s: document.getElementById('update-card').dataset.updateStatus, dis: document.getElementById('update-check-now').disabled, on: document.getElementById('update-enabled').checked })`);
    assert.deepEqual(st, { s: 'desactivado', dis: true, on: false });
    await evaluate(`window.__next = window.__states.sinPublicaciones; { const t = document.getElementById('update-enabled'); t.checked = true; t.dispatchEvent(new Event('change')); }`);
    await settle();
    await evaluate(`document.getElementById('update-check-now').click()`);
    await settle();
    calls = await evaluate('window.__calls.slice()');
    assert.deepEqual(calls.slice(-2), ['setEnabled:true', 'check:true'], '«Buscar ahora» fuerza la comprobación');

    console.log('PASS T5 update UI: interruptor, Buscar ahora y fecha; aviso «disponible» con notas (shell.open) y Descargar; «Lista…» con firma y No instalar; sin publicaciones, errores y fallo del puente visibles; título con <img onerror> pintado como texto');
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); } catch (_) { /* ya cerrado */ }
    if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
    fail(Error('Browser closed'));
    try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 }); } catch (_) { /* perfil aún en uso: es una carpeta temporal de la prueba */ }
  }
};

if (require.main === module) module.exports().catch(error => { console.error(error); process.exitCode = 1; });
