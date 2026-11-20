// DOM real con puente simulado. No abre la cabina ni usa datos del usuario.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawn } = require('node:child_process');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');
const root = path.resolve(__dirname, '../../..');
const evidence = path.join(root, 'zig-out/test-evidence/terminal-dom');
const profiles = path.join(root, '.zig-cache/cab010-browser');
fs.mkdirSync(profiles, { recursive: true });
const profile = fs.mkdtempSync(path.join(profiles, 'profile-'));
const browser = spawn(resolveBrowser(), ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`,
  '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
const pending = new Map(), errors = [];
let buffer = '', sequence = 0, session, stderr = '';
browser.stderr.on('data', data => { stderr += data; });
const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
browser.on('error', fail);
browser.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
browser.stdio[4].on('data', data => {
  buffer += data.toString();
  let end;
  while ((end = buffer.indexOf('\0')) >= 0) {
    const message = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
    if (message.method === 'Runtime.exceptionThrown' || (message.method === 'Runtime.consoleAPICalled' && message.params.type === 'error')) errors.push(message);
    const request = pending.get(message.id);
    if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
  }
});
function send(method, params = {}, sessionId = session) {
  return new Promise((resolve, reject) => {
    const id = ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(Error(`Timeout ${method}: ${stderr}`)); }, 15000);
    pending.set(id, { resolve, reject, timer });
    browser.stdio[3].write(JSON.stringify({ id, method, params, sessionId }) + '\0');
  });
}
async function evaluate(expression) {
  const result = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  assert(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function main() {
  try {
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    const sources = Object.fromEntries(['terminal_reconnect', 'editor_label', 'terminal_styles'].map(name => [name, fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8')]));
    const initial = await evaluate(`(async () => {
      document.body.innerHTML='<h1>CK-CAB-010: DOM con puente simulado</h1><div id="terminal" style="height:300px"></div><div id="editor" style="height:240px"></div>';
      const sources=${JSON.stringify(sources)};
      function load(name) { const mod={exports:{}}; new Function('module','exports','require',sources[name])(mod,mod.exports,()=>{throw Error('unexpected import')}); return mod.exports; }
      load('terminal_styles').injectStylesheet();
      document.documentElement.style.cssText='--bg-main:#151719;--fg:#eceff4;--border:#404448;--font-code:Consolas,monospace;--accent:#88c0d0';
      document.body.style.cssText='padding:16px;overflow:auto;background:var(--bg-main);color:var(--fg)';
      window.TerminalClass=load('terminal_reconnect').XtermTerminal;
      const text='CAB010_PREVIA ñ\\r\\n';
      window.host={id:42,text,spawns:0,requests:[],kills:[]};
      window.bridgeClient={send:async(kind,payload)=>{host.requests.push({kind,payload});return {payload:{terminals:[{terminalId:host.id,shellPath:'cmd.exe',cols:80,rows:25,running:true,mode:'conpty'}]}};}};
      window.terminalCore={ptyRead:async(id,offset)=>{host.requests.push({kind:'pty.read',id,offset}); const bytes=new TextEncoder().encode(host.text); return {data:new TextDecoder().decode(bytes.slice(offset)),offset:bytes.length};},
        ptyWrite:async(id,data)=>{host.lastWrite={id,data};},ptyResize:async()=>({}),ptyKill:async(id)=>{host.kills.push(id);},
        ptySpawn:async()=>{host.spawns++;return {terminalId:++host.id,mode:'conpty'};}};
      window.terminal=new TerminalClass(document.querySelector('#terminal'),terminalCore);
      await terminal.start();terminal.stopPolling();
      const editor=Object.create(load('editor_label').MonacoEditor.prototype);
      Object.assign(editor,{container:document.querySelector('#editor'),language:'typescript',filePath:'',content:'',onChangeCallbacks:[]});
      editor.render(); window.editor=editor;
      return {id:terminal.terminalId,spawns:host.spawns,output:document.querySelector('#term-output-plain').textContent,
        label:document.querySelector('#code-textarea').getAttribute('aria-label')};
    })()`);
    assert.equal(initial.id, 42); assert.equal(initial.spawns, 0);
    assert.equal(initial.label, 'Editor de código');
    assert.equal(initial.output.split('CAB010_PREVIA').length - 1, 1);
    console.log('PASS DOM: sesión 42 reconectada, historial una vez y textarea simple con nombre accesible');
    const replay = await evaluate(`(async()=>{
      document.querySelector('#term-input').value='echo TEST';document.querySelector('#term-input').dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true}));
      await Promise.resolve();const write=host.lastWrite;
      host.text+='CAB010_NUEVA\\r\\n';await terminal.pollOnce();
      const live=document.querySelector('#term-output-plain').textContent;
      const secondHost=document.createElement('div');document.body.appendChild(secondHost);
      window.secondTerminal=new TerminalClass(secondHost,terminalCore);await secondTerminal.start();secondTerminal.stopPolling();
      return {write,id:secondTerminal.terminalId,spawns:host.spawns,live,replayed:secondHost.querySelector('#term-output-plain').textContent};
    })()`);
    assert.equal(replay.write.id, 42); assert.equal(replay.write.data, 'echo TEST\r\n');
    assert.equal(replay.id, 42); assert.equal(replay.spawns, 0);
    for (const text of [replay.live, replay.replayed]) {
      assert.equal(text.split('CAB010_PREVIA').length - 1, 1);
      assert.equal(text.split('CAB010_NUEVA').length - 1, 1);
    }
    console.log('PASS DOM: entrada al mismo id, salida nueva sin duplicados y segunda WebUI sin spawn');
    const monacoLabel = await evaluate(`(async()=>{
      window.monaco={languages:{getLanguages:()=>[{id:'html'},{id:'zig'},{id:'toml'}]},editor:{defineTheme(){},setTheme(){},create(host){
        host.innerHTML='<textarea class="ime-text-area"></textarea>';
        return {getModel:()=>({updateOptions(){}}),onDidChangeModelContent(){},onDidChangeCursorPosition(){},getValue:()=>'',getPosition:()=>({lineNumber:1,column:1})};
      }}};
      await editor.initMonaco();
      return document.querySelector('#editor-monaco-host #code-textarea')?.getAttribute('aria-label');
    })()`);
    assert.equal(monacoLabel, 'Editor de código');
    console.log('PASS DOM: input de Monaco simulado con nombre accesible');
    assert.deepEqual(errors, [], 'errores de consola del navegador');
    fs.mkdirSync(evidence, { recursive: true });
    fs.writeFileSync(path.join(evidence, 'dom-simulado.txt'), await evaluate('document.body.innerText'));
    const screenshot = await send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(evidence, 'dom-simulado.png'), Buffer.from(screenshot.data, 'base64'));
    console.log('PASS 3/3 grupos DOM; consola sin errores; captura y texto guardados (puente y Monaco simulados)');
  } finally {
    browser.kill();
    await new Promise(resolve => { if (browser.exitCode !== null) resolve(); else browser.once('exit', resolve); });
    fs.rmSync(profile, { recursive: true, force: true, maxRetries: 20, retryDelay: 100 });
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
