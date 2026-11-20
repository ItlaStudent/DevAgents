const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const ts = require('../shell/webui/node_modules/typescript');
const { resolveBrowser } = require('./browser_resolver.cjs');

const samples = [
  ['html', 'index.html', '<!-- note -->\n<div class="card">Hello</div>'],
  ['css', 'style.css', '/* note */\n.card { color: "red"; width: 24px; }'],
  ['javascript', 'app.js', '// note\nfunction greet() { return "hello" + 42; }'],
  ['typescript', 'app.ts', '// note\nfunction greet(name: string): number { return 42; }'],
  ['typescript', 'app.tsx', '// note\nconst count: number = 42; const view = <div title="hello"/>;'],
  ['json', 'data.json', '{ "message": "hello", "count": 42, "ready": true }'],
  ['markdown', 'readme.md', '# Heading\n**bold** and `code`\n[link](https://example.invalid)'],
  ['python', 'app.py', '# note\ndef greet():\n    return "hello" + str(42)'],
  ['zig', 'app.zig', '// note\npub fn greet() u32 { const text = "hello"; return 42; }'],
  ['c', 'app.c', '// note\nint greet(void) { const char *text = "hello"; return 42; }'],
  ['cpp', 'app.cpp', '// note\nclass Greeter { public: int greet() { return 42; } };'],
  ['c', 'app.h', '// note\n#define LIMIT 42\nint greet(void);'],
  ['rust', 'app.rs', '// note\nfn greet() -> u32 { let text = "hello"; 42 }'],
  ['go', 'app.go', '// note\nfunc greet() int { text := "hello"; return 42 }'],
  ['java', 'App.java', '// note\nclass Greeter { String text = "hello"; int count = 42; }'],
  ['shell', 'app.sh', '# note\nif true; then echo "hello"; exit 42; fi'],
  ['powershell', 'app.ps1', '# note\nfunction Greet { Write-Output "hello"; return 42 }'],
  ['yaml', 'data.yaml', '# note\nmessage: "hello"\ncount: 42\nready: true'],
  ['toml', 'data.toml', '# note\n[section]\nmessage = "hello"\ncount = 42\nready = true'],
  ['sql', 'query.sql', '-- note\nSELECT name FROM users WHERE id = 42 AND name = \'hello\';'],
  ['xml', 'data.xml', '<!-- note -->\n<item count="42">hello</item>'],
];

function sourcesFor(root, first) {
  const sources = {};
  function visit(file) {
    const key = path.relative(root, file).replaceAll('\\', '/');
    if (sources[key]) return;
    const source = fs.readFileSync(file, 'utf8');
    sources[key] = ts.transpileModule(source, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
    for (const match of source.matchAll(/from\s+['"]([^'"]+)['"]/g)) {
      if (match[1].startsWith('.')) visit(path.resolve(path.dirname(file), match[1] + '.ts'));
    }
  }
  for (const file of first) visit(path.join(root, file));
  return sources;
}

async function run() {
  const root = process.env.DEVAGENTS_MONACO_SOURCE || path.resolve(__dirname, '../shell/webui/src');
  const vendorBase = pathToFileURL(path.resolve(__dirname, '../shell/webui') + path.sep).href;
  const executable = resolveBrowser();
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-monaco-browser-'));
  const html = path.join(profile, 'editor.html');
  fs.writeFileSync(html, `<!doctype html><html lang="es"><head><meta charset="utf-8"><base href="${vendorBase}"></head><body><main id="editor" style="width:1100px;height:620px"></main></body></html>`);
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', '--allow-file-access-from-files', `--user-data-dir=${profile}`, '--no-sandbox', '--disable-gpu', '--no-first-run', '--disable-background-networking', 'about:blank'], { cwd: profile, stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map(), errors = [];
  child.stderr.on('data', data => { stderr += data; });
  function fail(error) { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); }
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      if (message.method === 'Runtime.exceptionThrown') errors.push(JSON.stringify(message.params.exceptionDetails));
      if (message.method === 'Runtime.consoleAPICalled' && ['error', 'warning'].includes(message.params.type)) errors.push(JSON.stringify(message.params.args));
      const request = pending.get(message.id);
      if (request) { clearTimeout(request.timer); pending.delete(message.id); message.error ? request.reject(Error(JSON.stringify(message.error))) : request.resolve(message.result); }
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
  let checks = 0;
  try {
    const { targetId } = await send('Target.createTarget', { url: pathToFileURL(html).href }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    await send('Emulation.setDeviceMetricsOverride', { width: 1280, height: 800, deviceScaleFactor: 1, mobile: false });
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
    const sources = sourcesFor(root, ['editor/monaco_editor.ts', 'design/theme_registry.ts', 'design/stylesheet.ts']);
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)}, cache={};
      function load(file) {
        if(cache[file])return cache[file].exports;
        const mod={exports:{}};cache[file]=mod;
        new Function('module','exports','require',sources[file])(mod,mod.exports,name=>{
          const parts=file.split('/');parts.pop();
          for(const part of name.split('/')){if(part==='..')parts.pop();else if(part!=='.')parts.push(part);}
          return load(parts.join('/')+'.ts');
        });return mod.exports;
      }
      load('design/stylesheet.ts').injectStylesheet();
      window.themes=load('design/theme_registry.ts').themes;
      window.useTheme=id=>{
        for(const [name,value]of Object.entries(window.themes[id].colors))document.documentElement.style.setProperty('--'+name.replace(/[A-Z]/g,letter=>'-'+letter.toLowerCase()).replace(/(surface)(\\d)/,'$1-$2'),value);
      };
      window.useTheme('black');
      window.sourceText='';
      window.testEditor=new (load('editor/monaco_editor.ts').MonacoEditor)(document.querySelector('#editor'),{send:async()=>({content:window.sourceText})});
    })()`);
    await evaluate("new Promise((resolve,reject)=>{const start=Date.now();const timer=setInterval(()=>{if(window.testEditor.monacoEd){clearInterval(timer);resolve();}else if(Date.now()-start>15000){clearInterval(timer);reject(Error('Real Monaco editor did not mount'));}},25)})");
    const registered = await evaluate('monaco.languages.getLanguages().map(language=>language.id)');
    console.log('REGISTERED ' + JSON.stringify(registered));
    for (const [language, file, text] of samples) {
      await evaluate(`window.sourceText=${JSON.stringify(text)};window.testEditor.openFile(${JSON.stringify(file)})`);
      await evaluate("new Promise(resolve=>setTimeout(resolve,150))");
      const actual = await evaluate("({language:window.testEditor.monacoEd.getModel().getLanguageId(),label:document.querySelector('#editor-lang').textContent,tokens:monaco.editor.tokenize(window.sourceText,window.testEditor.monacoEd.getModel().getLanguageId()).flat().map(token=>token.type),colors:[...document.querySelectorAll('.view-lines span[class^=mtk]')].map(element=>getComputedStyle(element).color)})");
      console.log('LANGUAGE ' + file + ' ' + JSON.stringify(actual));
      assert(registered.includes(language), `Missing registered language: ${language}`);
      assert.equal(actual.language, language);
      assert.equal(actual.label, (language === 'cpp' ? 'c++' : language).toUpperCase());
      assert(new Set(actual.tokens.filter(Boolean)).size >= 2, `Missing real tokenization: ${file}`);
      assert(new Set(actual.colors).size >= 2, `Code renders in one color: ${file}`);
      checks++;
    }
    for (const theme of ['black', 'light']) {
      const zig = samples.find(([language]) => language === 'zig');
      await evaluate(`window.useTheme('${theme}');window.sourceText=${JSON.stringify(zig[2])};window.testEditor.openFile('app.zig')`);
      await evaluate("new Promise(resolve=>setTimeout(resolve,150))");
      const tokens = await evaluate("monaco.editor.tokenize(window.sourceText,'zig').flat().map(token=>token.type)");
      for (const role of ['keyword', 'string', 'comment', 'number', 'type', 'function']) assert(tokens.some(token => token === role || token.startsWith(role + '.')), `Zig token ${role} absent`);
      const colors = await evaluate("[...document.querySelectorAll('.view-lines span[class^=mtk]')].map(element=>getComputedStyle(element).color)");
      assert(new Set(colors).size >= 6, `${theme}: expected six distinct rendered syntax colors`);
      console.log('THEME ' + theme + ' ' + JSON.stringify(colors));
      if (process.env.DEVAGENTS_MONACO_CAPTURE_DIR) {
        const prefix = path.join(process.env.DEVAGENTS_MONACO_CAPTURE_DIR, 'E5.REL-monaco-' + theme + '-' + new Date().toISOString().replace(/[-:.]/g, ''));
        fs.writeFileSync(prefix + '.innerText.txt', await evaluate('document.body.innerText'));
        const shot = await send('Page.captureScreenshot', { format: 'png' });
        fs.writeFileSync(prefix + '.png', Buffer.from(shot.data, 'base64'));
        console.log('CAPTURE=' + prefix + '.png');
      }
      checks++;
    }
    const zig = samples.find(([language]) => language === 'zig');
    await evaluate('window.useTheme("black")');
    await evaluate(`window.sourceText=${JSON.stringify(zig[2])};window.testEditor.openFile('app.zig')`);
    const before = await evaluate('window.testEditor.monacoEd.getValue()');
    await evaluate("window.testEditor.monacoEd.focus()");
    await send('Input.insertText', { text: '// user edit\n' });
    assert.notEqual(await evaluate('window.testEditor.monacoEd.getValue()'), before, 'Real editor must remain editable');
    checks++;
    console.log('INNER_TEXT=' + await evaluate('document.body.innerText'));
    console.log('CONSOLE_ERRORS=' + JSON.stringify(errors));
    assert.equal(errors.length, 0, 'No page console/worker errors');
    console.log(`MONACO BROWSER ${checks}/${checks} passed`);
  } finally {
    if (child.exitCode === null && child.pid) { const exited = new Promise(resolve => child.once('exit', resolve)); child.kill(); await exited; }
    fail(Error('Browser closed'));
    if (stderr) console.log('BROWSER_STDERR=' + stderr);
    assert(path.resolve(profile).startsWith(path.resolve(os.tmpdir()) + path.sep), 'Cleanup must remain in temporary directory');
    try { fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 }); console.log('TEMP_REMOVED=' + profile); } catch (_) { /* Chromium suelta el perfil de forma asincrona en Windows */ }
  }
}
if (require.main === module) run().catch(error => { console.error(error); process.exitCode = 1; });
module.exports = { run, samples };
