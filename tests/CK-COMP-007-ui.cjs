const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const dist = path.join(root, 'shell/webui/dist');
const { CoreApi } = require(path.join(dist, 'cli_quota_api.test.cjs'));
const { quotaLevel, unknownQuota } = require(path.join(dist, 'cli_quota.test.cjs'));
const { resolveBrowser } = require('./browser_resolver.cjs');
const evidence = process.env.DEVAGENTS_TEST_EVIDENCE || path.join(root, 'zig-out/test-evidence/cli-quota');

(async () => {
  assert.equal(quotaLevel({ used_percent: null, reset_at: null }), 'unknown');
  assert.equal(quotaLevel({ used_percent: 79, reset_at: null }), 'normal');
  assert.equal(quotaLevel({ used_percent: 80, reset_at: null }), 'warning');
  assert.equal(quotaLevel({ used_percent: 100, reset_at: null }), 'exhausted');
  const normal = unknownQuota('claude-code');
  const warning = { ...unknownQuota('codex'), five_hour: { used_percent: 80, reset_at: 1800005000 } };
  let kind;
  const api = new CoreApi({ send: async k => { kind = k; return { status: 'ok', payload: [{ provider: 'agent:codex', quota: warning }] }; } });
  const data = await api.getCliQuotas();
  assert.equal(kind, 'core.external.agents');
  assert.equal(data[0].five_hour.used_percent, 80);
  assert.equal(data[1].weekly.used_percent, null);

  fs.mkdirSync(path.join(root, '.zig-cache'), { recursive: true }); // con --cache-dir externa la carpeta no existe
  const profile = fs.mkdtempSync(path.join(root, '.zig-cache/comp007-browser-'));
  const child = spawn(resolveBrowser(), ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-sandbox', '--disable-gpu', '--no-first-run', '--disable-background-networking', '--disable-component-update', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map(), errors = [];
  child.stderr.on('data', d => { stderr += d; });
  const fail = e => { for (const p of pending.values()) { clearTimeout(p.timer); p.reject(e); } pending.clear(); };
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Chrome exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', d => {
    buffer += d.toString();
    let i;
    while ((i = buffer.indexOf('\0')) >= 0) {
      const m = JSON.parse(buffer.slice(0, i)); buffer = buffer.slice(i + 1);
      if (m.method === 'Runtime.exceptionThrown' || (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error')) errors.push(m);
      const p = pending.get(m.id);
      if (p) { clearTimeout(p.timer); pending.delete(m.id); m.error ? p.reject(Error(JSON.stringify(m.error))) : p.resolve(m.result); }
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 60000);
      pending.set(id, { resolve, reject, timer });
      child.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
    });
  }
  async function evaluate(expression) {
    const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  try {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    session = (await send('Target.attachToTarget', { targetId, flatten: true })).sessionId;
    await send('Runtime.enable');
    const source = fs.readFileSync(path.join(dist, 'cli_quota.test.cjs'), 'utf8');
    const styles = fs.readFileSync(path.join(dist, 'cli_quota_styles.test.cjs'), 'utf8');
    await evaluate(`(() => {
      function load(source){const module={exports:{}};new Function('module','exports',source)(module,module.exports);return module.exports;}
      load(${JSON.stringify(styles)}).injectStylesheet();
      document.body.style.cssText='background:#181c19;color:#ddd;font:13px sans-serif;margin:0';
      const footer=document.createElement('footer');footer.style.cssText='position:fixed;bottom:0;padding:10px;background:#252a26;width:100%';document.body.append(footer);
      window.data=${JSON.stringify(data)};
      window.panel=new (load(${JSON.stringify(source)}).CliQuotaStatus)({getCliQuotas:async()=>window.data},footer);
      window.panel.start();
    })()`);
    await evaluate('panel.refresh()');
    assert.equal(await evaluate("document.querySelectorAll('progress').length"), 1);
    assert.equal(await evaluate("document.querySelector('#beats-notices')?.childElementCount || 0"), 1, 'un aviso visible al 80 %');
    await evaluate('panel.refresh()');
    assert.equal(await evaluate("document.querySelector('#beats-notices')?.childElementCount || 0"), 1, 'el sondeo no duplica el aviso visible');
    assert(await evaluate("document.querySelector('summary').textContent.includes('Claude Code: sin datos')"));
    await evaluate("document.querySelector('summary').click()");
    assert.equal(await evaluate("document.querySelector('details').open"), true);
    assert.equal(await evaluate("getComputedStyle(document.querySelector('[data-level=warning]')).color"), 'rgb(200, 146, 70)');
    await evaluate('data[0].five_hour.used_percent=100;panel.render(data)');
    assert.equal(await evaluate("document.querySelector('#beats-notices')?.childElementCount || 0"), 2);
    assert(await evaluate("document.querySelector('.cli-quota__body').textContent.includes('CLI omitida: cuota agotada')"));
    assert.equal(await evaluate("getComputedStyle(document.querySelector('[data-level=exhausted]')).color"), 'rgb(196, 85, 61)');
    assert(await evaluate("document.querySelector('.cli-quota__body').textContent.includes('Formato sin verificar')"));
    const shot = await send('Page.captureScreenshot', { format: 'png' });
    fs.mkdirSync(evidence, { recursive: true });
    fs.writeFileSync(path.join(evidence, 'cuotas-cabina-fixture.png'), Buffer.from(shot.data, 'base64'));
    await evaluate("panel.core.getCliQuotas=async()=>{throw Error('fixture: puente no disponible')};panel.refresh()");
    assert.equal(await evaluate("document.querySelectorAll('progress').length"), 0);
    assert(await evaluate("document.querySelector('summary').title.includes('fixture: puente no disponible')"));
    await evaluate('panel.stop()');
    assert.deepEqual(errors, []);
    console.log('CK-COMP-007 UI PASS: puente existente, 79/80/100/desconocido, aviso visible único, clic real, tema, captura, error de puente; BROWSER_ERRORS=[]');
  } finally {
    if (child.pid && child.exitCode === null && child.signalCode === null) {
      const exited = new Promise(resolve => child.once('exit', resolve));
      child.kill();
      await exited;
    }
    assert(profile.startsWith(path.join(root, '.zig-cache') + path.sep), 'Browser profile must stay inside this worktree');
    try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 }); } catch (_) { /* Chromium suelta el perfil de forma asincrona en Windows */ }
  }
})().catch(e => { console.error(e); process.exitCode = 1; });
