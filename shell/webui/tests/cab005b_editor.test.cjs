// Registro de producción y clases reales. DOM, Monaco y transporte son dobles;
// no ejecuta la cabina ni demuestra su renderizado visual.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const src = path.resolve(__dirname, '../src');

class Element {
  constructor() {
    this.style = {}; this.dataset = {}; this.children = []; this.nodes = new Map();
    this.events = {}; this.value = ''; this.selectionStart = this.selectionEnd = 0;
    this.isConnected = true; this.classList = { toggle() {}, add() {}, remove() {} };
  }
  set innerHTML(html) {
    this.html = html; this.nodes.clear(); this.children = [];
    for (const match of html.matchAll(/id="([^"]+)"/g)) this.nodes.set('#' + match[1], new Element());
    if (html.includes('monaco-editor-host')) { const host = new Element(); this.nodes.set('.monaco-editor-host', host); this.children.push(host); }
    let n = 0;
    for (const match of html.matchAll(/data-hunk-id="([^"]+)"/g)) {
      const e = new Element(); e.dataset.hunkId = match[1]; this.nodes.set(`[data-hunk-id="${match[1]}"]`, e); n++;
    }
  }
  get innerHTML() { return this.html || ''; }
  get firstElementChild() { return this.children[0]; }
  querySelector(sel) { return this.nodes.get(sel) ?? null; }
  querySelectorAll(sel) {
    if (sel === '[data-hunk-id]') return [...this.nodes.values()].filter(n => n.dataset.hunkId);
    return [];
  }
  appendChild(e) { this.children.push(e); e.parentElement = this; return e; }
  remove() { this.isConnected = false; if (this.parentElement) this.parentElement.children = this.parentElement.children.filter(c => c !== this); }
  addEventListener(name, fn) { (this.events[name] ??= []).push(fn); }
  async emit(name, detail = {}) { for (const fn of this.events[name] ?? []) await fn({ target: this, preventDefault() {}, stopPropagation() {}, ...detail }); }
  setAttribute(name, val) { this[name] = val; }
  removeAttribute(name) { delete this[name]; }
  focus() { this.focused = true; }
  select() {}
  setSelectionRange(a, b) { this.selectionStart = a; this.selectionEnd = b; }
  scrollIntoView(options) { this.scrolled = options; }
  dispatchEvent() {}
  contains(target) { return this === target || this.children.some(c => c.contains(target)); }
}

async function setup() {
  const notices = [], prompts = [], confirms = [], writes = [], calls = [], disk = new Map(), readonly = new Set();
  let root = 'C:\\fixture', matchesOverride;
  const document = { documentElement: new Element(), body: new Element(), head: new Element(),
    createElement: () => new Element(), addEventListener() {}, dispatchEvent() {}, getElementById: () => null };
  const models = [];
  const monaco = { languages: { getLanguages: () => [{ id: 'html' }], register() {}, setMonarchTokensProvider() {}, setLanguageConfiguration() {} },
    editor: { defineTheme() {}, setTheme() {}, setModelLanguage() {}, create(host, opts) {
      const handlers = []; const m = { value: opts.value, options: opts, position: { lineNumber: 1, column: 1 },
        getValue() { return this.value; }, setValue(v) { this.value = v; handlers.forEach(fn => fn()); },
        getModel() { return { updateOptions() {}, getLineCount: () => this.value.split('\n').length }; },
        onDidChangeModelContent(fn) { handlers.push(fn); }, onDidChangeCursorPosition() {},
        getPosition() { return this.position; }, setPosition(p) { this.position = p; },
        updateOptions(o) { Object.assign(this.options, o); }, saveViewState() { return this.position; }, restoreViewState(s) { this.position = s; },
        focus() { this.focused = true; }, layout() {}, dispose() { this.disposed = true; },
        getAction() { return this.action; }, pushUndoStop() {},
      }; models.push(m); return m;
    } } };
  const context = vm.createContext({ console, document, window: { monaco }, Number, Map, Set, Event: class {}, CustomEvent: class {},
    getComputedStyle: () => ({ getPropertyValue: () => '', lineHeight: '20px' }),
    MutationObserver: class { observe() {} disconnect() {} }, setTimeout, clearTimeout });
  const imports = {
    '../design/notice': { notice: (msg, kind) => notices.push([msg, kind]) },
    '../design/modal': { promptModal: async () => prompts.shift() ?? null, confirmModal: async () => confirms.shift() ?? false },
    '../design/icons': { icons: new Proxy({}, { get: () => () => '' }) },
  };
  function load(relative) {
    const code = ts.transpileModule(fs.readFileSync(path.join(src, relative), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    const mod = { exports: {} };
    vm.compileFunction(code, ['module', 'exports', 'require'], { parsingContext: context })(mod, mod.exports, n => imports[n] ?? {});
    return mod.exports;
  }
  imports['../design/html'] = load('design/html.ts');
  imports['./highlight'] = load('editor/highlight.ts');
  imports['./binario'] = load('editor/binario.ts');
  imports['../editor/binario'] = imports['./binario'];
  imports['./monaco_color'] = load('editor/monaco_color.ts');
  imports['./monaco_language'] = load('editor/monaco_language.ts');
  imports['./file_actions'] = load('editor/file_actions.ts');
  imports['../editor/diff_viewer'] = load('editor/diff_viewer.ts');
  const { MonacoEditor } = load('editor/monaco_editor.ts');
  const { DiffViewer } = imports['../editor/diff_viewer'];
  const { ViewRouter } = load('app/view_router.ts');
  const { CommandPalette } = load('components/command_palette.ts');
  const { TabManager } = load('layout/tab_manager.ts');
  const tabs = new TabManager();
  const bridge = { async send(method, args) {
    calls.push([method, args]);
    if (method === 'doc.open') { assert(disk.has(args.path), 'fixture existente'); return { payload: { path: args.path, content: disk.get(args.path), readOnly: readonly.has(args.path) } }; }
    assert.equal(method, 'doc.save'); assert.equal(args.force, false);
    if (readonly.has(args.path)) throw Error('E_SAVE_OPEN_FAILED: solo lectura');
    writes.push({ ...args }); disk.set(args.path, args.content); return { payload: { saved: true } };
  } };
  const core = {
    async listDir() { return { root, entries: [] }; }, async repoEmbedStatus() { return { state: 'empty' }; },
    async search(query, rootDir) {
      calls.push(['search.query', { query, rootDir }]);
      if (matchesOverride) return matchesOverride;
      return [...disk].filter(([file, content]) => file.startsWith(rootDir + '\\') && content.toLowerCase().includes(query.toLowerCase()))
        .map(([filePath, lineContent]) => ({ filePath, lineNumber: 1, lineContent }));
    },
    async openDoc(path) { return (await bridge.send('doc.open', { path })).payload; },
    async saveDoc(path, content, force = false) { return bridge.send('doc.save', { path, content, force }); },
  };
  const editor = new MonacoEditor(new Element(), bridge);
  await new Promise(resolve => setImmediate(resolve));
  const diff = Object.create(DiffViewer.prototype);
  Object.assign(diff, { container: new Element(), core, path: '', hunks: [], ops: [], loading: false });
  const router = Object.create(ViewRouter.prototype);
  Object.assign(router, { core, hooks: { hasUnsavedChanges: p => editor.isDirty(p), onFilesReplaced: async paths => { for (const p of paths) await editor.reloadSavedFile(p); } },
    treeRoot: '', current: 'search' });
  router.show = view => { router.current = view; if (view === 'search') router.renderSearch(body); };
  router.showEditor = () => { router.current = 'editor'; };
  const body = new Element(); document.getElementById = id => body.querySelector('#' + id);
  const palette = Object.create(CommandPalette.prototype);
  Object.assign(context, { activeEditor: editor, primaryEditor: editor, diffViewer: diff, router,
    tabManager: tabs, commandPalette: palette,
    notice: imports['../design/notice'].notice, toggleBrowser() {}, togglePanel() {}, reviewCurrentFile() {}, changeWorkspaceRoot() {},
    themeManager: { getAvailableThemes: () => [] }, helpPanel: { show() {} } });
  const main = fs.readFileSync(path.join(src, 'main.ts'), 'utf8');
  const focusStart = main.indexOf('  if (primaryEditor) primaryEditor.onFocus');
  const focusAst = ts.createSourceFile('main.ts', main, ts.ScriptTarget.Latest, true);
  let focusEnd;
  (function visit(node) { if (ts.isIfStatement(node) && node.getStart(focusAst) === focusStart + 2) focusEnd = node.end; ts.forEachChild(node, visit); })(focusAst);
  assert(focusEnd, 'callback real del foco');
  vm.runInContext(ts.transpileModule(main.slice(focusStart, focusEnd), { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText, context);
  const start = main.indexOf('  // 7. Comandos de la paleta.');
  const call = main.indexOf('commandPalette.registerCommands(', start);
  const ast = ts.createSourceFile('main.ts', main, ts.ScriptTarget.Latest, true); let end;
  (function visit(node) { if (ts.isCallExpression(node) && node.getStart(ast) === call) end = node.end; ts.forEachChild(node, visit); })(ast);
  assert(end, 'registro real');
  vm.runInContext(ts.transpileModule(main.slice(start, end) + ';', { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText, context);
  const command = id => { const item = palette.commands.find(c => c.id === id); assert(item, `el comando ${id} no existe en la paleta`); return item; };
  const open = async (p, text) => { disk.set(p, text); tabs.openTab(p, p); await editor.openFile(p); };
  const flush = () => new Promise(resolve => setImmediate(resolve));
  return { editor, diff, router, core, bridge, tabs, command, open, notices, models, prompts, confirms, writes, calls, disk, readonly, body, flush,
    setRoot: r => { root = r; }, setMatches: m => { matchesOverride = m; } };
}

for (const [suffix, direction] of [['Vertical', 'row'], ['Horizontal', 'column']]) {
  test(`CK-CAB-005 B dividir ${suffix}: dos superficies, mismo/distinto archivo, borradores y cierre`, async () => {
    const f = await setup(); const cmd = f.command('editor.split' + suffix);
    await f.open('C:\\fixture\\a.txt', 'uno'); f.editor.monacoEd.setValue('borrador A');
    await cmd.action(); await f.flush();
    const other = f.editor.splitEditor;
    assert(other, 'panel secundario creado'); assert.equal(f.editor.container.style.flexDirection, direction);
    assert.equal(other.getValue(), 'borrador A'); assert.equal(f.editor.monacoEd.disposed, undefined);
    other.monacoEd.setValue('ambos'); assert.equal(f.editor.getValue(), 'ambos'); assert(f.editor.isDirty('C:\\fixture\\a.txt'));
    f.editor.monacoEd.setPosition({ lineNumber: 1, column: 3 });
    other.monacoEd.setPosition({ lineNumber: 1, column: 2 });
    f.disk.set('C:\\fixture\\b.txt', 'dos'); await other.openFile('C:\\fixture\\b.txt'); other.monacoEd.setValue('borrador B');
    assert.equal(f.editor.getValue(), 'ambos');
    await f.command('editor.split' + (suffix === 'Vertical' ? 'Horizontal' : 'Vertical')).action();
    assert.equal(f.editor.splitEditor, other, 'reorientar conserva las instancias');
    await f.command('editor.closeSplit').action();
    assert.equal(f.editor.splitEditor, null); assert(other.monacoEd === null || other.monacoEd.disposed);
    await f.editor.openFile('C:\\fixture\\a.txt'); assert.equal(f.editor.getValue(), 'ambos');
    await f.editor.openFile('C:\\fixture\\b.txt'); assert.equal(f.editor.getValue(), 'borrador B'); assert.equal(f.writes.length, 0);
  });
}

test('CK-CAB-005 B hunks: registro real, orden, límites, foco y nuevo diff', async () => {
  const f = await setup(); const next = f.command('diff.nextHunk'), prev = f.command('diff.prevHunk');
  const original = Array.from({ length: 40 }, (_, i) => 'línea ' + i); const proposed = [...original];
  proposed[1] = 'cambio A'; proposed[20] = 'cambio B'; proposed[38] = 'cambio C';
  f.disk.set('C:\\fixture\\diff.txt', original.join('\n'));
  await f.diff.showDiff('C:\\fixture\\diff.txt', proposed.join('\n'));
  assert.equal(f.diff.hunks.length, 3);
  for (const id of [1, 2, 3, 3]) { await next.action(); const e = f.diff.container.querySelector(`[data-hunk-id="${id}"]`); assert(e.focused); assert(e.scrolled); }
  for (const id of [2, 1, 1]) { await prev.action(); assert.equal(f.diff.focusedHunk, id - 1); }
  await f.diff.showDiff('C:\\fixture\\diff.txt', proposed.join('\n')); await prev.action(); assert.equal(f.diff.focusedHunk, 2);
  await f.diff.showDiff('C:\\fixture\\diff.txt', original.join('\n')); await next.action(); assert.equal(f.diff.focusedHunk, -1);
});

test('CK-CAB-005 B formatear: proveedor real de la acción, ausencia y fallo sin escrituras', async () => {
  const f = await setup(); const cmd = f.command('editor.formatDocument');
  await f.open('C:\\fixture\\a.ts', 'let a=1'); await cmd.action();
  assert.equal(f.editor.getValue(), 'let a=1'); assert.match(f.notices.at(-1)[0], /sin formateador para este lenguaje/i);
  let ran = 0; f.editor.monacoEd.action = { isSupported: () => true, async run() { ran++; f.editor.monacoEd.setValue('let a = 1;\n'); } };
  await cmd.action(); assert.equal(ran, 1); assert.equal(f.editor.getValue(), 'let a = 1;\n'); assert(f.editor.isDirty('C:\\fixture\\a.ts'));
  f.editor.monacoEd.action = { isSupported: () => false, run() { throw Error('no llamar'); } }; await cmd.action(); assert.equal(ran, 1);
  f.editor.monacoEd.action = { isSupported: () => true, run() { throw Error('proveedor falló'); } }; await cmd.action(); assert.match(f.notices.at(-1)[0], /proveedor falló/);
  assert.equal(f.writes.length, 0);
});

async function preview(f, query = 'uno', replacement = 'dos') {
  await f.command('search.replaceInFiles').action();
  f.body.querySelector('#search-input').value = query;
  f.body.querySelector('#search-replacement').value = replacement;
  await f.body.querySelector('#search-replace-preview').emit('click');
}

test('CK-CAB-005 B reemplazo: vista previa, solo lectura, confirmación cancelada sin escrituras', async () => {
  const f = await setup(); f.command('search.replaceInFiles');
  f.disk.set('C:\\fixture\\a.txt', 'UNO uno\r\nfinal'); f.disk.set('C:\\fixture\\ro.txt', 'uno'); f.readonly.add('C:\\fixture\\ro.txt');
  await preview(f); const result = f.body.querySelector('#search-replace-results');
  assert.match(result.innerHTML, /UNO uno/); assert.match(result.innerHTML, /dos dos/); assert.match(result.innerHTML, /solo lectura/i);
  assert.equal(f.writes.length, 0); f.confirms.push(false);
  await f.body.querySelector('#search-replace-apply').emit('click'); assert.equal(f.writes.length, 0);
  f.confirms.push(true); await f.body.querySelector('#search-replace-apply').emit('click');
  assert.equal(f.writes.length, 1); assert.equal(f.disk.get('C:\\fixture\\a.txt'), 'dos dos\r\nfinal'); assert.equal(f.disk.get('C:\\fixture\\ro.txt'), 'uno');
  assert(f.calls.some(([m]) => m === 'doc.save')); assert(!f.calls.some(([m]) => m === 'search.replace'));
});

test('CK-CAB-005 B reemplazo: botón Cancelar invalida una vista previa pendiente', async () => {
  const f = await setup(); f.command('search.replaceInFiles'); f.disk.set('C:\\fixture\\a.txt', 'uno');
  await preview(f); await f.body.querySelector('#search-replace-cancel').emit('click');
  f.confirms.push(true); await f.body.querySelector('#search-replace-apply').emit('click'); assert.equal(f.writes.length, 0);
});

test('CK-CAB-005 B reemplazo: raíz activa, ruta ajena, cambios posteriores y borradores', async () => {
  const f = await setup(); f.command('search.replaceInFiles'); f.disk.set('C:\\fixture\\a.txt', 'uno');
  await preview(f); f.setRoot('C:\\otra'); f.confirms.push(true);
  await f.body.querySelector('#search-replace-apply').emit('click'); assert.equal(f.writes.length, 0);
  assert.match(f.body.querySelector('#search-replace-results').textContent, /raíz activa cambió/);
  f.setRoot('C:\\fixture'); f.setMatches([{ filePath: 'C:\\fixture-escape\\a.txt' }]);
  await preview(f); assert.equal(f.calls.filter(([m, a]) => m === 'doc.open' && a.path.includes('escape')).length, 0);
  assert.match(f.body.querySelector('#search-replace-results').textContent, /fuera de la raíz/);
  f.setMatches(undefined); await preview(f); f.disk.set('C:\\fixture\\a.txt', 'externo'); f.confirms.push(true);
  await f.body.querySelector('#search-replace-apply').emit('click'); assert.equal(f.writes.length, 0);
  assert.match(f.body.querySelector('#search-replace-results').textContent, /cambió o es de solo lectura/);
  await f.open('C:\\fixture\\a.txt', 'uno'); f.editor.monacoEd.setValue('mi borrador'); await preview(f);
  assert.match(f.body.querySelector('#search-replace-results').innerHTML, /sin guardar/); assert.equal(f.writes.length, 0);
});

test('CK-CAB-005 B split: foco actualiza pestaña y dirige el comando al panel enfocado', async () => {
  const f = await setup(); await f.open('C:\\fixture\\a.ts', 'A');
  await f.command('editor.splitVertical').action(); await f.flush(); const other = f.editor.splitEditor;
  f.disk.set('C:\\fixture\\b.ts', 'B'); f.tabs.openTab('C:\\fixture\\b.ts', 'B'); await other.openFile('C:\\fixture\\b.ts');
  await f.editor.container.emit('focusin'); assert.equal(f.tabs.getActiveTab().path, 'C:\\fixture\\a.ts');
  await other.container.emit('focusin'); assert.equal(f.tabs.getActiveTab().path, 'C:\\fixture\\b.ts');
  let ran = 0; other.monacoEd.action = { isSupported: () => true, run() { ran++; } };
  await f.command('editor.formatDocument').action(); assert.equal(ran, 1);
  await f.command('editor.closeSplit').action(); assert.equal(f.tabs.getActiveTab().path, 'C:\\fixture\\a.ts');
});

test('CK-CAB-005 B reemplazo: Cancelar durante la última consulta previa a escribir mantiene el lote intacto', async () => {
  const f = await setup(); f.disk.set('C:\\fixture\\a.txt', 'uno'); await preview(f);
  let finish, queried = 0;
  f.core.listDir = async () => {
    queried++; if (queried === 2) return new Promise(resolve => { finish = resolve; });
    return { root: 'C:\\fixture', entries: [] };
  };
  f.confirms.push(true); const applying = f.body.querySelector('#search-replace-apply').emit('click');
  await f.flush(); assert(finish, 'escritura todavía no iniciada');
  await f.body.querySelector('#search-replace-cancel').emit('click'); finish({ root: 'C:\\fixture' }); await applying;
  assert.equal(f.writes.length, 0); assert.equal(f.disk.get('C:\\fixture\\a.txt'), 'uno');
});

test('CK-CAB-005 B reemplazo: dos confirmaciones concurrentes no guardan dos veces el mismo plan', async () => {
  const f = await setup(); f.disk.set('C:\\fixture\\a.txt', 'uno'); await preview(f);
  f.confirms.push(true, true);
  const apply = f.body.querySelector('#search-replace-apply'); await Promise.all([apply.emit('click'), apply.emit('click')]);
  assert.equal(f.writes.length, 1);
});

test('CK-CAB-005 B split: editar mientras abre la segunda vista conserva el texto y dirty en ambas', async () => {
  const f = await setup(); await f.open('C:\\fixture\\a.ts', 'disco');
  let finish; f.bridge.send = async () => new Promise(resolve => { finish = resolve; });
  const split = f.command('editor.splitVertical').action(); await f.flush();
  f.editor.monacoEd.setValue('edición durante apertura');
  finish({ payload: { content: 'disco' } }); await split;
  assert.equal(f.editor.getValue(), 'edición durante apertura');
  assert.equal(f.editor.splitEditor.getValue(), 'edición durante apertura'); assert(f.editor.isDirty('C:\\fixture\\a.ts'));
});

test('CK-CAB-005 B split: cerrar mientras abre no resucita la vista ni pierde borradores', async () => {
  const f = await setup(); await f.open('C:\\fixture\\a.ts', 'disco');
  let finish; f.bridge.send = async () => new Promise(resolve => { finish = resolve; });
  const split = f.command('editor.splitHorizontal').action(); await f.flush();
  await f.command('editor.closeSplit').action(); finish({ payload: { content: 'disco' } }); await split;
  assert.equal(f.editor.splitEditor, null); assert.equal(f.editor.getValue(), 'disco');
});

test('CK-CAB-005 B split: guardar desde el segundo limpia los indicadores de las dos vistas', async () => {
  const f = await setup(); await f.open('C:\\fixture\\a.ts', 'disco');
  await f.command('editor.splitVertical').action(); const other = f.editor.splitEditor;
  other.monacoEd.setValue('nuevo'); await other.saveCurrentFile();
  assert.equal(f.disk.get('C:\\fixture\\a.ts'), 'nuevo'); assert.equal(f.editor.isDirty('C:\\fixture\\a.ts'), false);
  assert.equal(f.editor.container.querySelector('#editor-dirty-flag').style.display, 'none');
  assert.equal(other.container.querySelector('#editor-dirty-flag').style.display, 'none');
});

test('CK-CAB-005 B split: editar la otra vista durante guardar mantiene el borrador nuevo pendiente', async () => {
  const f = await setup(); await f.open('C:\\fixture\\a.ts', 'disco');
  await f.command('editor.splitVertical').action(); const other = f.editor.splitEditor;
  other.monacoEd.setValue('primero'); await other.container.emit('focusin');
  let finish; f.bridge.send = async (method, args) => new Promise(resolve => { finish = () => {
    assert.equal(method, 'doc.save'); f.disk.set(args.path, args.content); resolve({ payload: { saved: true } });
  }; });
  const saving = f.command('file.save').action(); await f.flush();
  f.editor.monacoEd.setValue('edición posterior'); finish(); await saving;
  assert.equal(f.disk.get('C:\\fixture\\a.ts'), 'primero'); assert.equal(other.getValue(), 'edición posterior');
  assert(f.editor.isDirty('C:\\fixture\\a.ts')); assert.equal(f.editor.buffers.get('C:\\fixture\\a.ts'), 'edición posterior');
});

test('CK-CAB-005 B reemplazo: solo lectura detectada antes de aplicar evita escribir cualquier archivo', async () => {
  const f = await setup(); f.disk.set('C:\\fixture\\a.txt', 'uno'); f.disk.set('C:\\fixture\\b.txt', 'uno'); await preview(f);
  f.readonly.add('C:\\fixture\\b.txt'); f.confirms.push(true);
  await f.body.querySelector('#search-replace-apply').emit('click');
  assert.equal(f.writes.length, 0); assert.match(f.body.querySelector('#search-replace-results').textContent, /solo lectura/);
});

test('CK-CAB-005 B reemplazo: cancelación durante búsqueda descarta la respuesta tardía', async () => {
  const f = await setup(); f.disk.set('C:\\fixture\\a.txt', 'uno'); await f.command('search.replaceInFiles').action();
  let finish; f.core.search = async () => new Promise(resolve => { finish = resolve; });
  f.body.querySelector('#search-input').value = 'uno';
  const preparing = f.body.querySelector('#search-replace-preview').emit('click'); await f.flush();
  await f.body.querySelector('#search-replace-cancel').emit('click');
  finish([{ filePath: 'C:\\fixture\\a.txt' }]); await preparing;
  assert.equal(f.body.querySelector('#search-replace-results').innerHTML, '');
  assert.equal(f.body.querySelector('#search-replace-apply').disabled, true); assert.equal(f.writes.length, 0);
});

test('CK-CAB-005 B reemplazo: sustitución vacía, texto literal y recarga de las dos vistas limpias', async () => {
  const f = await setup(); await f.open('C:\\fixture\\a.ts', 'a.$ a.$\r\nfin');
  await f.command('editor.splitVertical').action();
  await preview(f, 'a.$', ''); assert.match(f.body.querySelector('#search-replace-results').innerHTML, /coincidencias/);
  f.confirms.push(true); await f.body.querySelector('#search-replace-apply').emit('click');
  assert.equal(f.disk.get('C:\\fixture\\a.ts'), ' \r\nfin'); assert.equal(f.editor.getValue(), ' \r\nfin');
  assert.equal(f.editor.splitEditor.getValue(), ' \r\nfin'); assert.equal(f.editor.isDirty('C:\\fixture\\a.ts'), false);
});
