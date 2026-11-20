// Chromium real, MissionControlPanel real; CoreApi y credencial sintéticas.
// Sin cabina, red, administrador de credenciales real ni proveedores.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { test } = require('node:test');
const { buildSync } = require('esbuild');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

test('CK-MCP-004 renovación por botón real, compare, reintento y secreto ausente', { timeout: 60000 }, async t => {
  const root = path.resolve(__dirname, '../../..');
  const tempRoot = path.join(root, '.zig-cache/mcp004-browser');
  fs.mkdirSync(tempRoot, { recursive: true });
  const profile = fs.mkdtempSync(path.join(tempRoot, 'profile-'));
  const html = path.join(profile, 'fixture.html');
  fs.writeFileSync(html, '<!doctype html><html lang="es"><meta charset="utf-8"><body></body></html>');
  const bundle = buildSync({ entryPoints: [path.join(root, 'shell/webui/src/panes/mission_control.ts')], bundle: true, write: false, format: 'iife', globalName: 'MCP004', platform: 'browser' }).outputFiles[0].text;
  const design = buildSync({ stdin: { contents: "import {injectStylesheet} from './src/design/stylesheet'; import {ThemeManager} from './src/design/theme_registry'; injectStylesheet(); new ThemeManager().applyTheme('black');", resolveDir: path.join(root, 'shell/webui') }, bundle: true, write: false, platform: 'browser' }).outputFiles[0].text;
  const child = spawn(resolveBrowser(), ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-sandbox', '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map();
  const errors = [];
  const fail = error => { for (const p of pending.values()) { clearTimeout(p.timer); p.reject(error); } pending.clear(); };
  child.stderr.on('data', data => { stderr += data; });
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let end;
    while ((end = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
      if (message.method === 'Runtime.exceptionThrown') errors.push(message.params.exceptionDetails);
      if (message.method === 'Runtime.consoleAPICalled') errors.push(message.params.type);
      const p = pending.get(message.id);
      if (p) { clearTimeout(p.timer); pending.delete(message.id); message.error ? p.reject(Error(JSON.stringify(message.error))) : p.resolve(message.result); }
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}`)); }, 10000);
      pending.set(id, { resolve, reject, timer });
      child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }
  async function evaluate(expression) {
    const r = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!r.exceptionDetails, String(r.exceptionDetails?.exception?.description || 'Excepción en fixture de navegador').replaceAll('synthetic-mcp004-password', '[redactado]'));
    return r.result.value;
  }
  async function click(selector) {
    const point = await evaluate(`(() => { const e=document.querySelector(${JSON.stringify(selector)}); if(!e)throw Error('Control ausente'); e.scrollIntoView({block:'center'}); const r=e.getBoundingClientRect(); if(!r.width||!r.height)throw Error('Control oculto'); return {x:r.x+r.width/2,y:r.y+r.height/2}; })()`);
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
    await evaluate('new Promise(resolve=>setTimeout(resolve,30))');
  }
  async function mount(mode = 'success') {
    await evaluate(`(() => {
      window.calls=[]; window.prompts=0; window.mode=${JSON.stringify(mode)};
      window.prompt=()=>{window.prompts++;throw Error('Prompt automático prohibido')};
      window.alert=window.confirm=window.prompt;
      window.secret='synthetic-mcp004-password';
      document.body.innerHTML='<div id="host" style="width:900px;height:900px"></div>';
      window.core={
        status:async()=>({engineReady:true,keyCount:1}),
        getDeterministic:async()=>({enabled:false}),
        getAgenticIterations:async()=>({iterations:3}),
        listProviders:async()=>[],
        discoverAgents:async()=>[],
        getPlanModel:async()=>({provider:'',model:''}),
        getModelSelection:async()=>[],
        storeGitCredential:async(host,user,pass)=>{
          calls.push({method:'store',host,user,secretMatches:pass===secret});
          if(mode==='error')throw Error('helper rejected '+pass+' while saving');
          return {stored:mode!=='rejected',host};
        },
        shipOrder:async(id)=>{calls.push({method:'ship',id});return {pr:{number:42,url:'https://forge.invalid/acme/widget/pulls/42'}}},
        prs:async()=>[{id:42,number:42,repo:'acme/widget',state:'open',url:'https://forge.invalid/acme/widget/pulls/42'}],
        openPath:async(url)=>{calls.push({method:'open',url});},
      };
      window.panel=new MCP004.MissionControlPanel(document.querySelector('#host'),core);
      panel.orderId=7;panel.phase='done';panel.shipManual={branch:'beats/orden-7',url:'https://forge.invalid/acme/widget/compare/main...beats/orden-7'};
      panel.renderBody();
      return true;
    })()`);
  }
  async function fill() {
    await evaluate(`document.querySelector('#ship-cred-user').value='fixture';document.querySelector('#ship-cred-pass').value=secret;true`);
  }
  async function capture(name) {
    if (!process.env.MCP004_EVIDENCE) return;
    const target = path.resolve(process.env.MCP004_EVIDENCE, name);
    const text = await evaluate('document.body.innerText');
    assert(!text.includes('synthetic-mcp004-password'), 'Captura sin secreto');
    fs.writeFileSync(target + '.txt', 'FIXTURE SINTÉTICO: WebUI real, CoreApi doblada.\n' + text);
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(target + '.png', Buffer.from(shot.data, 'base64'));
  }
  const watchdog = setTimeout(() => child.kill(), 55000);
  try {
    const { targetId } = await send('Target.createTarget', { url: pathToFileURL(html).href }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    await send('Emulation.setDeviceMetricsOverride', { width: 1100, height: 1100, deviceScaleFactor: 1, mobile: false });
    await send('Network.enable');
    await send('Network.setBlockedURLs', { urls: ['http://*', 'https://*'] });
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
    await evaluate(design + '\n' + bundle + ';true');

    await t.test('CK-MCP-004 etiqueta, explicación y compare sin petición automática', async () => {
      await mount();
      assert.deepEqual(await evaluate('({calls,prompts})'), { calls: [], prompts: 0 });
      assert.equal(await evaluate("document.querySelector('#btn-ship-cred').textContent"), 'Renovar credencial');
      const text = await evaluate('document.body.innerText');
      assert.match(text, /push.*termin[oó]/i);
      assert.match(text, /autorizaci[oó]n.*API/);
      assert.match(text, /administrador de credenciales de Git/);
      assert.match(text, /mano/);
      await capture('tarjeta-manual');
      await click('.pr-url');
      assert.deepEqual(await evaluate('calls'), [{ method: 'open', url: 'https://forge.invalid/acme/widget/compare/main...beats/orden-7' }]);
    });
    await t.test('CK-MCP-004 clic renueva para el host, confirma y reintenta abriendo el PR', async () => {
      await mount(); await fill();
      assert.deepEqual(await evaluate('calls'), []);
      assert.equal(await evaluate("document.querySelector('#ship-cred-pass').type"), 'password');
      await click('#btn-ship-cred');
      assert.deepEqual(await evaluate('calls'), [{ method: 'store', host: 'forge.invalid', user: 'fixture', secretMatches: true }, { method: 'ship', id: 7 }]);
      assert.equal(await evaluate('panel.shipManual'), null);
      assert.equal(await evaluate("document.querySelector('.pr-url').dataset.url"), 'https://forge.invalid/acme/widget/pulls/42');
      await capture('pr-reintentado');
    });
    await t.test('CK-MCP-004 rechazo del almacén no reintenta', async () => {
      await mount('rejected'); await fill(); await click('#btn-ship-cred');
      assert.deepEqual(await evaluate('calls.map(c=>c.method)'), ['store']);
      assert.match(await evaluate("document.querySelector('#ship-cred-status').textContent"), /no confirm[oó]/);
    });
    await t.test('CK-MCP-004 error externo no muestra ni registra el token', async () => {
      await mount('error'); await fill(); await click('#btn-ship-cred');
      assert.deepEqual(await evaluate('calls.map(c=>c.method)'), ['store']);
      const text = await evaluate("document.querySelector('#ship-cred-status').textContent");
      assert(text.length > 0, 'Error visible');
      assert(!text.includes('synthetic-mcp004-password'), 'Error sin token');
      assert(await evaluate('!document.body.innerHTML.includes(secret)'));
      assert.deepEqual(errors, [], 'Sin excepciones ni mensajes de consola');
      await capture('error-seguro');
    });
  } finally {
    clearTimeout(watchdog);
    const exited = new Promise(resolve => child.once('exit', resolve));
    if (child.exitCode === null) { await send('Browser.close', {}, undefined); await exited; }
    fail(Error('Browser cerrado'));
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 15, retryDelay: 100 });
  }
});
