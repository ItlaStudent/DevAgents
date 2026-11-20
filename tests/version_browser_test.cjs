const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');

module.exports = async function versionUi() {
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-comp004-'));
  const executable = process.env.DEVAGENTS_TEST_BROWSER || 'C:/Program Files/Google/Chrome/Application/chrome.exe';
  const html = path.join(profile, 'version.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', '--disable-component-update', '--disable-sync', '--host-resolver-rules=MAP * ~NOTFOUND', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session;
  const pending = new Map();
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
    }
  });
  function send(method, params = {}, sessionId = session) {
    return new Promise((resolve, reject) => {
      const id = ++next;
      const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 15000);
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
    const {targetId} = await send('Target.createTarget', {url: pathToFileURL(html).href}, undefined);
    session = (await send('Target.attachToTarget', {targetId, flatten:true}, undefined)).sessionId;
    await send('Page.enable');
    await send('Emulation.setDeviceMetricsOverride', {width:1100,height:650,deviceScaleFactor:1,mobile:false});
    const bundle = fs.readFileSync(path.join(__dirname, '../shell/webui/dist/version.test.cjs'), 'utf8');
    await evaluate(`(() => { const module={exports:{}};new Function('module','exports',${JSON.stringify(bundle)})(module,module.exports);window.versionUi=module.exports;})()`);
    assert.equal(await evaluate(`(async () => {
      document.body.innerHTML='<button id=continue>Continuar</button>';
      const identity=versionUi.buildIdentity;
      const pass=await versionUi.checkVersion({version:async()=>({host:identity,engine:identity})});
      window.clicked=false;document.getElementById('continue').onclick=()=>window.clicked=true;
      return pass && !document.querySelector('[role=alert]');
    })()`), true);
    await evaluate(`document.getElementById('continue').click()`);
    assert.equal(await evaluate('window.clicked'),true);
    for (const [host,engine,expected] of [
      ['host-old','host-old','host-old'],
      ['0.1.0+0123456789ab/abi1.bus1.ui1','dll-old','dll-old'],
      ['0.1.0+0123456789ab/abi1.bus1.ui1','0.1.0/abi1.bus1.ui1','0.1.0/abi1.bus1.ui1'],
      ['0.1.0/abi1.bus1.ui1','0.1.0/abi1.bus1.ui1','0.1.0/abi1.bus1.ui1']
    ]) {
      const result=await evaluate(`(async()=>{
        const pass=await versionUi.checkVersion({version:async()=>({host:${JSON.stringify(host)},engine:${JSON.stringify(engine)}})});
        const el=document.querySelector('[role=alert]');
        return {pass,text:el?.textContent,visible:!!el && el.getBoundingClientRect().height>0};
      })()`);
      assert.equal(result.pass,false);assert.equal(result.visible,true);
      assert.ok(result.text.includes('0.1.0+0123456789ab/abi1.bus1.ui1'));
      assert.ok(result.text.includes(expected));assert.match(result.text,/Actualiza/);
      if (expected === '0.1.0/abi1.bus1.ui1') assert.match(result.text,/build sin identidad de git/);
    }
    const screenshot=await send('Page.captureScreenshot',{format:'png'});
    const evidence=path.join(__dirname,'../zig-out/test-evidence/version-browser');
    fs.mkdirSync(evidence, { recursive: true });
    fs.writeFileSync(path.join(evidence,'version-browser-r2.png'),Buffer.from(screenshot.data,'base64'));
    console.log('CK-COMP-004 Chromium PIPE: 5/5 PASS; matching UI remains interactive; host/WebUI and host/DLL warnings visible with both values; hashless host and DLL show build sin identidad de git. Screenshot: version-browser-r2.png. Backend doubles, no cabina.');
  } finally {
    try { if(child.exitCode===null) await send('Browser.close',{},undefined); }
    finally {
      if(child.exitCode===null) await new Promise(resolve=>{child.once('exit',resolve);setTimeout(()=>{if(child.exitCode===null)child.kill();},3000).unref();});
      fail(Error('Browser closed'));
      fs.rmSync(profile,{recursive:true,force:true,maxRetries:10,retryDelay:200});
    }
  }
};
if(require.main===module)module.exports().catch(e=>{console.error(e);process.exitCode=1;});
