// (botón «Copiar» en bloques de código) y (Canvas y
// Diff en gris sin archivo). DOM real en Chromium por CDP, mismo arnés que
// cabina_ux_browser.cjs; el portapapeles es un doble, no el del sistema.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const { resolveBrowser } = require('../../../tests/browser_resolver.cjs');

module.exports = async function codeCopyFileActions() {
  const executable = resolveBrowser();
  const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'beats-ux-copy-'));
  const html = path.join(profile, 'copy.html');
  fs.writeFileSync(html, '<!doctype html><html><head><meta charset="utf-8"></head><body></body></html>');
  const child = spawn(executable, ['--headless=new', '--remote-debugging-pipe', `--user-data-dir=${profile}`, '--no-first-run', '--disable-background-networking', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe', 'pipe', 'pipe'], windowsHide: true });
  let buffer = '', next = 0, session, stderr = '';
  const pending = new Map();
  const browserErrors = [];
  child.stderr.on('data', data => { stderr += data; });
  const fail = error => { for (const request of pending.values()) { clearTimeout(request.timer); request.reject(error); } pending.clear(); };
  child.on('error', fail);
  child.on('exit', code => fail(Error(`Browser exit ${code}: ${stderr}`)));
  child.stdio[4].on('data', data => {
    buffer += data.toString();
    let index;
    while ((index = buffer.indexOf('\0')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      if (message.method === 'Runtime.exceptionThrown') browserErrors.push(message);
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
  const wait = ms => evaluate(`new Promise(resolve => setTimeout(resolve, ${ms}))`);
  async function center(selector) {
    return evaluate(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return { x: r.x + r.width / 2, y: r.y + r.height / 2 }; })()`);
  }
  async function move(point) { await send('Input.dispatchMouseEvent', { type: 'mouseMoved', ...point }); await wait(60); }
  async function click(selector) {
    await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({ block: 'center' })`);
    const point = await center(selector);
    await move(point);
    for (const type of ['mousePressed', 'mouseReleased']) await send('Input.dispatchMouseEvent', { type, ...point, button: 'left', clickCount: 1 });
    await wait(40);
  }
  async function tab() {
    for (const type of ['keyDown', 'keyUp']) await send('Input.dispatchKeyEvent', { type, key: 'Tab', code: 'Tab', windowsVirtualKeyCode: 9 });
    await wait(30);
  }
  try {
    const url = pathToFileURL(html).href;
    const { targetId } = await send('Target.createTarget', { url }, undefined);
    session = (await send('Target.attachToTarget', { targetId, flatten: true }, undefined)).sessionId;
    await send('Runtime.enable');
    const deadline = Date.now() + 10000;
    const ready = () => evaluate(`location.href===${JSON.stringify(url)} && document.readyState==='complete' && document.head!==null`)
      .catch(error => { if (/context was destroyed|Cannot find context/i.test(error.message)) return false; throw error; });
    while (!await ready()) {
      assert(Date.now() < deadline, `Timeout waiting for document: ${url}`);
      await new Promise(resolve => setTimeout(resolve, 25));
    }
    await send('Emulation.setDeviceMetricsOverride', { width: 900, height: 700, deviceScaleFactor: 1, mobile: false });
    const names = ['markdown_ux', 'code_copy_ux', 'file_actions_ux', 'monaco_editor_ux', 'stylesheet_ux', 'tokens_ux', 'html_ux', 'highlight_ux'];
    const sources = Object.fromEntries(names.map(name => [name, fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8')]));
    await evaluate(`(() => {
      const sources=${JSON.stringify(sources)};
      window.notices=[];
      const imports={'../design/notice':{notice:(m,k)=>window.notices.push([m,k])},'./notice':{notice:(m,k)=>window.notices.push([m,k])},
        '../design/icons':{icons:new Proxy({},{get:()=>()=>''})},'../design/modal':{confirmModal:async()=>true},
        './highlight':{highlight:t=>t,langFor:()=>'text'},'./binario':{pareceBinario:()=>false},'./monaco_color':{aHex:c=>c},
        './monaco_language':{monacoLanguageFor:()=>'plaintext',registerProjectLanguages(){}}};
      const cache={};
      function load(name){if(cache[name])return cache[name];const mod={exports:{}};new Function('module','exports','require',sources[name])(mod,mod.exports,n=>imports[n]||{});return cache[name]=mod.exports;}
      imports['./tokens']=imports['../design/tokens']=load('tokens_ux');
      imports['./html']=imports['../design/html']=load('html_ux');
      imports['./file_actions']=load('file_actions_ux');
      imports['../editor/highlight']=load('highlight_ux');
      load('stylesheet_ux').injectStylesheet();
      window.mods={renderMarkdown:load('markdown_ux').renderMarkdown,copy:load('code_copy_ux'),MonacoEditor:load('monaco_editor_ux').MonacoEditor};
      window.copied=[];
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async t=>{window.copied.push(t);}}});
    })()`);

    // Cada ficha se ejecuta aislada: si una falla, la otra se sigue comprobando y
    // el informe final lista las dos (el rojo muestra ambas).
    const failures = [];
    try {
    // ───────────── · Copiar ─────────────
    const jsBlock = "const a = '<b>&amp;</b>';\nif (a) {\n  return `x`; // <img src=x onerror=alert(1)>\n}";
    const shBlock = 'npm test -- --grep "uno"\ngit status';
    const md = 'Texto previo\n\n```js\n' + jsBlock + '\n```\n\nentre medias\n\n```bash\n' + shBlock + '\n```\n\n```\nsin lenguaje\n```\n';
    await evaluate(`(() => {
      const root=document.createElement('div');root.id='chat';root.style.cssText='width:600px;margin:40px auto';
      root.className='md';root.innerHTML=window.mods.renderMarkdown(${JSON.stringify(md)});
      document.body.appendChild(root);window.mods.copy.installCodeCopy(root);
    })()`);
    assert.equal(await evaluate("document.querySelectorAll('#chat pre.md-pre').length"), 3, 'tres bloques renderizados');
    assert.equal(await evaluate("document.querySelectorAll('#chat pre.md-pre .md-copy').length"), 3, 'CK-VER1-013: un botón Copiar por bloque');
    assert.equal(await evaluate("[...document.querySelectorAll('#chat .md-copy')].every(b=>b.tagName==='BUTTON'&&b.type==='button'&&b.getAttribute('aria-label')==='Copiar código'&&b.textContent==='Copiar')"), true, 'CK-VER1-013: aria-label y texto');
    assert.equal(await evaluate("document.querySelectorAll('#chat img').length"), 0, 'el modelo no inyecta marcado');
    // Esquina superior derecha del bloque.
    const geo = await evaluate("(() => { const pre=document.querySelector('#chat pre.md-pre'), b=pre.querySelector('.md-copy'); const p=pre.getBoundingClientRect(), r=b.getBoundingClientRect(); return { right: p.right - r.right, top: r.top - p.top, width: r.width }; })()");
    assert(geo.right >= 0 && geo.right <= 12 && geo.top >= 0 && geo.top <= 12, 'CK-VER1-013: esquina superior derecha ' + JSON.stringify(geo));
    // Visibilidad: oculto en reposo, visible con ratón y con foco de teclado.
    await move({ x: 2, y: 2 }); await wait(400);
    assert.equal(await evaluate("getComputedStyle(document.querySelector('#chat .md-copy')).opacity"), '0', 'reposo: oculto');
    await move(await center('#chat pre.md-pre')); await wait(400);
    assert.equal(await evaluate("getComputedStyle(document.querySelector('#chat .md-copy')).opacity"), '1', 'con el ratón encima: visible');
    await move({ x: 2, y: 2 });
    await evaluate("document.activeElement && document.activeElement.blur(); document.querySelector('#chat').scrollIntoView()");
    let guard = 0;
    while (!await evaluate("document.activeElement && document.activeElement.classList.contains('md-copy')")) { await tab(); assert(++guard < 8, 'Tab no llegó a ningún Copiar'); }
    await wait(400);
    assert.equal(await evaluate("getComputedStyle(document.activeElement).opacity"), '1', 'con foco de teclado: visible');
    assert.equal(await evaluate("document.activeElement.matches(':focus-visible')"), true);
    // Copia el texto EXACTO del bloque (sin lenguaje, sin números de línea, sin «Copiar»).
    await click('#chat pre.md-pre .md-copy');
    assert.deepEqual(await evaluate('window.copied'), [jsBlock], 'CK-VER1-013: texto exacto del bloque js');
    assert.equal(await evaluate("document.querySelector('#chat .md-copy').textContent"), 'Copiado', 'confirmación breve');
    assert.equal(await evaluate("document.querySelector('#chat .md-copy').getAttribute('aria-label')"), 'Código copiado');
    await wait(1800);
    assert.equal(await evaluate("document.querySelector('#chat .md-copy').textContent"), 'Copiar', 'la confirmación se retira');
    assert.equal(await evaluate("document.querySelector('#chat .md-copy').getAttribute('aria-label')"), 'Copiar código');
    // Segundo y tercer bloque; el de comando conserva su «Ejecutar esto».
    assert.equal(await evaluate("document.querySelectorAll('#chat .md-cmd__run').length"), 1, 'Ejecutar esto sigue solo en el bloque de comando');
    await click('#chat pre.md-pre:nth-of-type(2) .md-copy');
    assert.equal((await evaluate('window.copied')).at(-1), shBlock, 'bloque bash exacto');
    await click('#chat pre.md-pre:nth-of-type(3) .md-copy');
    assert.equal((await evaluate('window.copied')).at(-1), 'sin lenguaje');
    assert.equal(await evaluate('window.copied.length'), 3);
    // Fallo del portapapeles: aviso de error y SIN «Copiado».
    await wait(1800);
    await evaluate("Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async()=>{throw new Error('denegado');}}});document.execCommand=()=>false");
    await click('#chat pre.md-pre .md-copy');
    assert.equal(await evaluate("document.querySelector('#chat .md-copy').textContent"), 'Copiar', 'fallo: no se confirma');
    assert.equal(await evaluate('window.notices.at(-1)[1]'), 'error', 'fallo: aviso de error');
    console.log('PASS CK-VER1-013 Copiar: 3 bloques, aria-label, esquina sup. derecha, visible con ratón/teclado, texto exacto, confirmación y fallo explícito');

    } catch (error) { failures.push('CK-VER1-013: ' + error.message); }
    try {
    // ───────────── · Canvas / Diff ─────────────
    await evaluate(`(() => {
      const host=document.createElement('div');host.id='ed';host.style.cssText='width:800px;height:240px;margin:20px auto;display:flex';
      document.body.appendChild(host);
      window.hooks={canvas:0,diff:0};
      window.fakeBridge={send:async(m,p)=>({payload:{content:'contenido de '+p.path}})};
      const ed=new window.mods.MonacoEditor(host,window.fakeBridge);
      ed.onOpenCanvas=()=>window.hooks.canvas++;ed.onReviewDiff=()=>window.hooks.diff++;
      window.ed=ed;
    })()`);
    const state = () => evaluate("['canvas','diff'].map(a=>{const b=document.querySelector('#ed #editor-act-'+a);return b?{disabled:b.disabled,aria:b.getAttribute('aria-disabled'),title:b.title,label:b.getAttribute('aria-label'),opacity:getComputedStyle(b).opacity,cursor:getComputedStyle(b).cursor}:null;})");
    let st = await state();
    assert(st[0] && st[1], 'CK-VER1-014: existen #editor-act-canvas y #editor-act-diff');
    for (const [i, name] of ['Canvas', 'Diff'].entries()) {
      assert.equal(st[i].disabled, true, name + ' disabled sin archivo');
      assert.equal(st[i].aria, 'true', name + ' aria-disabled sin archivo');
      assert.equal(st[i].title, `Abre un archivo para usar ${name}`, name + ' tooltip');
      assert.equal(st[i].label, name);
      assert.equal(st[i].opacity, '0.45', name + ' en gris');
      assert.equal(st[i].cursor, 'not-allowed');
    }
    await click('#ed #editor-act-canvas'); await click('#ed #editor-act-diff');
    assert.deepEqual(await evaluate('window.hooks'), { canvas: 0, diff: 0 }, 'deshabilitados no disparan nada');
    await evaluate("window.ed.openFile('C:/p/a.txt')");
    st = await state();
    for (const [i, name] of ['Canvas', 'Diff'].entries()) {
      assert.equal(st[i].disabled, false, name + ' habilitado con archivo');
      assert.equal(st[i].aria, 'false');
      assert.notEqual(st[i].title, `Abre un archivo para usar ${name}`, name + ' ya no pide abrir archivo');
      assert.equal(st[i].opacity, '1');
    }
    await click('#ed #editor-act-canvas'); await click('#ed #editor-act-diff');
    assert.deepEqual(await evaluate('window.hooks'), { canvas: 1, diff: 1 }, 'habilitados disparan su acción');
    // Dos archivos: cerrar uno que no es el activo no apaga nada; cerrar el último, sí.
    await evaluate("window.ed.openFile('C:/p/b.txt')");
    await evaluate("window.ed.forgetFile('C:/p/a.txt')");
    st = await state(); assert.equal(st[0].disabled || st[1].disabled, false, 'cerrar una pestaña inactiva no apaga las acciones');
    await evaluate("window.ed.forgetFile('C:/p/b.txt')");
    assert.equal(await evaluate('window.ed.getFilePath()'), '');
    st = await state();
    for (const [i, name] of ['Canvas', 'Diff'].entries()) {
      assert.equal(st[i].disabled, true, name + ' vuelve a gris al cerrar el último archivo');
      assert.equal(st[i].aria, 'true');
      assert.equal(st[i].title, `Abre un archivo para usar ${name}`);
    }
    console.log('PASS CK-VER1-014 Canvas/Diff: grises y con tooltip sin archivo, habilitados con uno, de nuevo grises al cerrar el último');
    assert.deepEqual(browserErrors, [], 'sin excepciones en el navegador');
    } catch (error) { failures.push('CK-VER1-014: ' + error.message); }
    try {
    // ───────────── · Resaltado en bloques del chat ─────────────
    const tsCode = "const x: number = 42; // nota\nfunction f() { return 'a' }";
    const pyCode = "def f(self):\n    return 'a'  # nota";
    const hostile = '<script>alert("x")</script> & \'q\' "d" </code></pre><img src=x onerror=1>\nconst s = "</code><b>";';
    const bashCode = 'if [ "$x" ]; then\n  echo ${x} $x "hola # cadena" \'literal # cadena\' # nota\nfi';
    const psCode = 'IF ($x) {\n  Get-ChildItem $env:PATH ${x} "$x # cadena" \'it\'\'s # literal\' # nota\n}';
    const shellCases = [['bash', bashCode], ['sh', bashCode], ['powershell', psCode], ['ps1', psCode]];
    const langs = [['ts', tsCode], ['js', tsCode], ['python', pyCode], ['py', pyCode], ['zig', 'const a = 1; // c\npub fn main() void {}'],
      ['cpp', 'int main() { return 0; } // c'], ['c', 'int x = 1;'], ['h', 'int x = 1;'], ['json', '{"a": 1, "b": true, "c": null}'], ['md', '# Titulo\n- uno\n> cita'], ...shellCases];
    const plain = [['rareza', 'const x = 1'], ['', 'const x = 1']];
    const fenced = (tag, code) => '```' + tag + '\n' + code + '\n```';
    const all = [...langs, ...plain, ['ts', hostile], ['bash', hostile], ['powershell', hostile], ['unknown', hostile]];
    await evaluate(`(() => {
      const root=document.createElement('div');root.id='hl';root.className='md';root.style.cssText='width:600px';
      root.innerHTML=window.mods.renderMarkdown(${JSON.stringify(all.map(([t, c]) => fenced(t, c)).join('\n\n'))});
      document.body.appendChild(root);window.mods.copy.installCodeCopy(root);window.copied.length=0;
      Object.defineProperty(navigator,'clipboard',{configurable:true,value:{writeText:async t=>{window.copied.push(t);}}});
    })()`);
    const blocks = await evaluate(`[...document.querySelectorAll('#hl pre.md-pre')].map(pre => { const code = pre.querySelector('code');
      return { text: code.textContent, spans: [...code.querySelectorAll('span')].map(s => s.className), tokens: [...code.querySelectorAll('span')].map(s => [s.className, s.textContent]), other: [...code.querySelectorAll('*:not(span)')].length,
        attrs: [...code.querySelectorAll('span')].every(s => s.attributes.length === 1 && s.hasAttribute('class')) }; })`);
    assert.equal(blocks.length, all.length, 'un </code></pre> del modelo no parte el bloque');
    const TOK = new Set(['tok-kw', 'tok-str', 'tok-com', 'tok-num', 'tok-key']);
    all.forEach(([tag, code], i) => {
      const b = blocks[i];
      assert.equal(b.text, code, `CK-CAB-028 texto intacto (${tag || 'sin etiqueta'})`);
      assert.equal(b.other, 0, 'solo spans dentro de <code>');
      assert(b.attrs, 'los spans solo llevan class');
      for (const c of b.spans) assert(TOK.has(c), 'clase fija: ' + c);
    });
    langs.forEach(([tag], i) => assert(blocks[i].spans.length > 0, `CK-CAB-028 ${tag}: produce spans con clase`));
    plain.forEach(([tag], i) => assert.equal(blocks[langs.length + i].spans.length, 0, `CK-CAB-028 ${tag || 'sin etiqueta'}: texto plano sin spans`));
    assert.equal(blocks.at(-1).spans.length, 0, 'lenguaje desconocido con payload hostil: plano');
    assert.equal(await evaluate("document.querySelectorAll('#hl script, #hl img, #hl b').length"), 0, 'el modelo no inyecta elementos');
    const rawHtml = await evaluate("document.querySelector('#hl').innerHTML");
    assert(!/<script|<img|<b>/.test(rawHtml), 'HTML sin etiquetas del modelo');
    assert(blocks[0].spans.includes('tok-kw') && blocks[0].spans.includes('tok-num') && blocks[0].spans.includes('tok-com') && blocks[0].spans.includes('tok-str'));
    assert(blocks[8].spans.includes('tok-key'), 'json: claves');
    shellCases.forEach(([tag], i) => {
      const tokens = blocks[10 + i].tokens;
      const expected = tag === 'bash' || tag === 'sh'
        ? [['tok-kw', 'if'], ['tok-kw', 'then'], ['tok-kw', 'fi'], ['tok-key', '${x}'], ['tok-key', '$x'], ['tok-str', '"hola # cadena"'], ['tok-str', "'literal # cadena'"], ['tok-com', '# nota']]
        : [['tok-kw', 'IF'], ['tok-kw', 'Get-ChildItem'], ['tok-key', '$x'], ['tok-key', '$env:PATH'], ['tok-key', '${x}'], ['tok-str', '"$x # cadena"'], ['tok-str', "'it''s # literal'"], ['tok-com', '# nota']];
      for (const token of expected) assert(tokens.some(t => t[0] === token[0] && t[1] === token[1]), `${tag}: token ${JSON.stringify(token)}`);
    });
    // La copia sigue siendo el codigo original, no el HTML ni el texto de los spans.
    await move({ x: 2, y: 2 });
    await click('#hl pre.md-pre:nth-of-type(1) .md-copy');
    await click(`#hl pre.md-pre:nth-of-type(${langs.length + plain.length + 1}) .md-copy`);
    await click('#hl pre.md-pre:nth-of-type(11) .md-copy');
    await click('#hl pre.md-pre:nth-of-type(13) .md-copy');
    await click(`#hl pre.md-pre:nth-of-type(${langs.length + plain.length + 2}) .md-copy`);
    await click(`#hl pre.md-pre:nth-of-type(${langs.length + plain.length + 3}) .md-copy`);
    assert.deepEqual(await evaluate('window.copied'), [tsCode, hostile, bashCode, psCode, hostile, hostile], 'CK-CAB-028: Copiar entrega el codigo original exacto, incluidos bash/PowerShell y sus payloads hostiles');
    // Colores de los temas existentes: contraste sobre surface1 (fondo del bloque).
    const load = name => { const mod = { exports: {} }; new Function('module', 'exports', 'require', fs.readFileSync(path.join(__dirname, '../dist', name + '.test.cjs'), 'utf8'))(mod, mod.exports, n => n === './tokens' ? load('tokens_ux') : {}); return mod.exports; };
    const { themes } = load('theme_registry_ux');
    const rgb = hex => [1, 3, 5].map(i => parseInt(hex.slice(i, i + 2), 16));
    const lum = ch => { const [r, g, b] = ch.map(v => v / 255).map(c => c <= .04045 ? c / 12.92 : ((c + .055) / 1.055) ** 2.4); return r * .2126 + g * .7152 + b * .0722; };
    const ratio = (a, b) => { const x = lum(a), y = lum(b); return (Math.max(x, y) + .05) / (Math.min(x, y) + .05); };
    const mix = (a, b, pa) => a.map((v, i) => Math.round(v * pa + b[i] * (1 - pa)));
    for (const th of Object.values(themes)) {
      const c = th.colors, bg = rgb(c.surface1);
      const tokenColors = { 'tok-kw': rgb(c.accent), 'tok-str': mix(rgb(c.success), rgb(c.fg), .7), 'tok-com': rgb(c.fgMuted), 'tok-num': rgb(c.warning), 'tok-key': rgb(c.accentHover) };
      for (const [cls, col] of Object.entries(tokenColors)) assert(ratio(col, bg) >= 4, `${th.id}/${cls} contraste ${ratio(col, bg).toFixed(2)} < 4`);
    }
    const css = await evaluate("[...document.styleSheets].flatMap(s => [...s.cssRules]).map(r => r.cssText).filter(t => t.includes('.md-pre .tok-')).join(' ')");
    assert(css.includes('var(--fg-muted)'), 'la hoja aplica --fg-muted a los comentarios del chat');
    assert(css.includes('color-mix'), 'la hoja mezcla --success con --fg para las cadenas del chat');
    console.log('PASS CK-CAB-028 resaltado: ' + langs.length + ' etiquetas con spans, ' + plain.length + ' sin tokenizador en texto plano, payload hostil escapado, copia exacta y contraste >= 4:1 en ' + Object.keys(themes).length + ' temas');
    } catch (error) { failures.push('CK-CAB-028: ' + error.message); }
    assert.deepEqual(failures, [], ['Pruebas CK-VER1-013/014 en rojo:', ...failures].join(String.fromCharCode(10)));
  } finally {
    try { if (child.exitCode === null) await send('Browser.close', {}, undefined); }
    finally {
      if (child.exitCode === null) await new Promise(resolve => { child.once('exit', resolve); setTimeout(() => { if (child.exitCode === null) child.kill(); }, 3000).unref(); });
      fail(Error('Browser closed'));
      fs.rmSync(profile, { recursive: true, force: true, maxRetries: 10, retryDelay: 200 });
    }
  }
};

if (require.main === module) module.exports().catch(error => { console.error(error); process.exitCode = 1; });
