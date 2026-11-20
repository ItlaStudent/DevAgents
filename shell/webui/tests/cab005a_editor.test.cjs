// Registro real de main + clases reales; DOM/Monaco/puente dobles, sin cabina.
// Igual que terminal_reconnect.test.cjs, monta los prototipos con superficies sintéticas.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('typescript');
const src = path.resolve(__dirname, '../src');

function setup() {
  const notices = [], keys = [], prompts = [], writes = [], disk = new Map();
  const document = { documentElement: { style: { zoom: '' } }, addEventListener(type, fn, capture) {
    if (type === 'keydown') keys.push({ fn, capture });
  } };
  const context = vm.createContext({ console, document, window: {}, Number, Map, Set, CustomEvent: class {},
    getComputedStyle: () => ({ lineHeight: '20px' }), Event: class {} });
  const imports = { '../design/notice': { notice: (m, kind) => notices.push([m, kind]) },
    '../design/modal': { confirmModal: async () => { throw Error('No debe descartar borradores'); },
      promptModal: async () => prompts.shift() ?? null } };
  function load(relative) {
    const code = ts.transpileModule(fs.readFileSync(path.join(src, relative), 'utf8'), {
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
    }).outputText;
    const mod = { exports: {} };
    vm.compileFunction(code, ['module', 'exports', 'require'], { parsingContext: context })(mod, mod.exports, n => imports[n] ?? {});
    return mod.exports;
  }
  imports['./highlight'] = load('editor/highlight.ts');
  imports['./binario'] = load('editor/binario.ts');
  imports['./monaco_language'] = load('editor/monaco_language.ts');
  const { MonacoEditor } = load('editor/monaco_editor.ts');
  const { TabManager } = load('layout/tab_manager.ts');
  const { CommandPalette } = load('components/command_palette.ts');
  const editor = Object.create(MonacoEditor.prototype);
  const state = { value: '', lineNumber: 1, column: 1, scrollTop: 240, scrollLeft: 30, options: {}, focused: false };
  const monaco = {
    getValue: () => state.value, setValue: v => { state.value = v; },
    getPosition: () => ({ lineNumber: state.lineNumber, column: state.column }),
    setPosition: p => Object.assign(state, p), revealLineInCenter: line => { state.revealed = line; },
    focus: () => { state.focused = true; }, getModel: () => ({ getLineCount: () => state.value.split('\n').length, updateOptions() {} }),
    updateOptions: opts => Object.assign(state.options, opts),
    getScrollTop: () => state.scrollTop, getScrollLeft: () => state.scrollLeft,
    setScrollPosition: p => Object.assign(state, p),
    saveViewState: () => ({ lineNumber: state.lineNumber }), restoreViewState: p => Object.assign(state, p),
  };
  Object.assign(editor, { content: '', filePath: '', binaryPath: null, monacoEd: monaco,
    buffers: new Map(), dirtyPaths: new Set(), viewStates: new Map(), onChangeCallbacks: [],
    wordWrap: false, minimapEnabled: false,
    container: { querySelector: () => null }, codeAreaElem: { style: {} }, statusLineElem: {},
    bridge: { async send(method, args) {
      if (method === 'doc.open') return { payload: { content: disk.get(args.path) ?? '' } };
      assert.equal(method, 'doc.save'); writes.push({ ...args });
      if (args.path === 'error.txt') throw Error('E_SAVE_CONFLICT');
      disk.set(args.path, args.content);
      return { payload: { saved: true } };
    } },
  });
  const tabs = new TabManager();
  tabs.onTabClose(tab => editor.forgetFile(tab.path));
  const palette = Object.create(CommandPalette.prototype);
  Object.assign(context, { activeEditor: editor, tabManager: tabs, commandPalette: palette,
    notice: imports['../design/notice'].notice,
    toggleBrowser() {}, togglePanel() {}, reviewCurrentFile() {}, changeWorkspaceRoot() {},
    router: { show() {} }, themeManager: { getAvailableThemes: () => [] }, helpPanel: { show() {} },
  });
  const main = fs.readFileSync(path.join(src, 'main.ts'), 'utf8');
  const start = main.indexOf('  // 7. Comandos de la paleta.');
  const call = main.indexOf('commandPalette.registerCommands(', start);
  const ast = ts.createSourceFile('main.ts', main, ts.ScriptTarget.Latest, true);
  let end;
  function visit(node) {
    if (ts.isCallExpression(node) && node.getStart(ast) === call) end = node.end;
    ts.forEachChild(node, visit);
  }
  visit(ast);
  assert(end, 'registro real localizado en main.ts');
  const registration = ts.transpileModule(main.slice(start, end) + ';', {
    compilerOptions: { target: ts.ScriptTarget.ES2022 },
  }).outputText;
  vm.runInContext(registration, context);
  // F6 (10-nov): los atajos ya no son manejadores fijos dentro de
  // este bloque de main.ts; los atiende el despachador único de keybindings.ts,
  // que main.ts instala justo después con la misma lista. Aquí se hace igual.
  const keybindings = load('app/keybindings.ts');
  keybindings.registerBindableCommands(palette.commands);
  keybindings.installKeybindings(document);
  function command(id) {
    const item = palette.commands.find(c => c.id === id);
    assert(item, `el comando ${id} no existe en la paleta`);
    return item;
  }
  async function open(file, value, dirty = false) {
    disk.set(file, value); tabs.openTab(file, file); await editor.openFile(file);
    if (dirty) edit(value + ' modificado');
  }
  function edit(text) { editor.content = state.value = text; editor.notifyChange(); }
  async function key(key, extra = {}) {
    let stopped = false;
    const e = { key, ctrlKey: false, metaKey: false, shiftKey: false, altKey: false,
      preventDefault() { this.prevented = true; }, stopPropagation() { stopped = true; },
      stopImmediatePropagation() { stopped = true; }, ...extra };
    for (const h of keys) { await h.fn(e); if (stopped) break; }
    return e;
  }
  return { editor, tabs, palette, command, open, edit, state, notices, prompts, writes, disk, document, key };
}

test('CK-CAB-005 Guardar todo: guarda todas las sucias, informa fallos, conserva activa y borradores', async () => {
  const f = setup(); const cmd = f.command('file.saveAll');
  assert.equal(cmd.label, 'Guardar todo');
  await f.open('a.txt', 'uno', true); await f.open('error.txt', 'dos', true); await f.open('b.txt', 'tres', true);
  await f.open('limpio.txt', 'cuatro');
  await cmd.action();
  assert.deepEqual(f.writes.map(w => w.path), ['a.txt', 'error.txt', 'b.txt']);
  assert(f.writes.every(w => w.force === false));
  assert.equal(f.disk.get('a.txt'), 'uno modificado'); assert.equal(f.disk.get('b.txt'), 'tres modificado');
  assert.equal(f.editor.isDirty('a.txt'), false); assert.equal(f.editor.isDirty('b.txt'), false);
  assert.equal(f.editor.isDirty('error.txt'), true); assert.equal(f.editor.buffers.get('error.txt'), 'dos modificado');
  assert.equal(f.editor.getFilePath(), 'limpio.txt'); assert.equal(f.editor.getValue(), 'cuatro');
  assert(f.notices.some(([m, k]) => k === 'error' && m.includes('error.txt')));
  const count = f.writes.length; await cmd.action(); assert.equal(f.writes.length, count + 1);
});

test('CK-CAB-005 Cerrar otras pestañas: conserva activa y sucias, cierra las limpias con su callback real', async () => {
  const f = setup(); const cmd = f.command('file.closeOthers');
  assert.equal(cmd.label, 'Cerrar otras pestañas');
  await f.open('limpia.txt', 'uno'); await f.open('sucia.txt', 'dos', true);
  const stale = f.tabs.getTabs().find(t => t.path === 'sucia.txt'); stale.isDirty = false;
  await f.open('marca.txt', 'tres'); f.tabs.setDirty(f.tabs.getActiveTab().id, true);
  await f.open('activa.txt', 'cuatro'); const active = f.tabs.getActiveTab().id;
  await cmd.action();
  assert.deepEqual(Array.from(f.tabs.getTabs(), t => t.path), ['sucia.txt', 'marca.txt', 'activa.txt']);
  assert.equal(f.tabs.getActiveTab().id, active); assert.equal(f.editor.getFilePath(), 'activa.txt');
  assert.equal(f.editor.buffers.has('limpia.txt'), false); assert.equal(f.editor.isDirty('sucia.txt'), true);
  assert(f.notices.some(([m]) => m.includes('2')));
  const empty = setup(); await empty.command('file.closeOthers').action(); assert.equal(empty.tabs.getTabs().length, 0);
});

test('CK-CAB-005 Ir a línea: extremos, inexistente, texto inválido y cancelación', async () => {
  const f = setup(); const cmd = f.command('editor.goToLine');
  assert.equal(cmd.label, 'Ir a línea'); assert.equal(cmd.shortcut, 'Ctrl+G');
  await f.open('lineas.txt', 'uno\ndos\ntres');
  for (const line of ['3', '1', ' 2 ']) {
    f.prompts.push(line); await cmd.action(); assert.equal(f.state.lineNumber, Number(line));
    assert.equal(f.state.column, 1); assert.equal(f.state.revealed, Number(line)); assert(f.state.focused);
  }
  for (const value of ['0', '-1', '4', '1.5', '2abc', '1e0', 'NaN', 'Infinity', '', '9007199254740993']) {
    f.prompts.push(value); await cmd.action(); assert.equal(f.state.lineNumber, 2);
    assert.equal(f.notices.at(-1)[1], 'error');
  }
  f.prompts.push(null); const count = f.notices.length; await cmd.action(); assert.equal(f.notices.length, count);
  await f.open('vacio.txt', ''); f.prompts.push('1'); await cmd.action(); assert.equal(f.state.lineNumber, 1);
  assert.equal((await f.key('g', { ctrlKey: true })).prevented, true);
});

test('CK-CAB-005 Ajuste de línea: alterna wordWrap y lo mantiene al cambiar de archivo', async () => {
  const f = setup(); const cmd = f.command('editor.toggleWordWrap');
  assert.equal(cmd.label, 'Ajuste de línea'); assert.equal(cmd.shortcut, 'Alt+Z');
  await f.open('a.txt', 'uno'); await cmd.action(); assert.equal(f.state.options.wordWrap, 'on');
  await f.open('b.txt', 'dos'); assert.equal(f.state.options.wordWrap, 'on');
  await cmd.action(); assert.equal(f.state.options.wordWrap, 'off'); assert.equal(f.editor.getValue(), 'dos');
  await f.key('z', { altKey: true }); assert.equal(f.state.options.wordWrap, 'on');
});

test('CK-CAB-005 Minimapa del editor: alterna sin cambiar contenido, scroll ni cursor', async () => {
  const f = setup(); const cmd = f.command('editor.toggleMinimap');
  assert.equal(cmd.label, 'Minimapa del editor');
  await f.open('a.txt', 'uno\ndos'); Object.assign(f.state, { scrollTop: 240, scrollLeft: 30, lineNumber: 2 });
  await cmd.action(); assert.equal(f.state.options.minimap.enabled, true);
  assert.equal(f.editor.getValue(), 'uno\ndos'); assert.equal(f.state.scrollTop, 240);
  assert.equal(f.state.scrollLeft, 30); assert.equal(f.state.lineNumber, 2);
  await f.open('b.txt', 'tres'); assert.equal(f.state.options.minimap.enabled, true);
  await cmd.action(); assert.equal(f.state.options.minimap.enabled, false);
  assert.equal(f.editor.isDirty('a.txt'), false);
});

test('CK-CAB-005 Zoom +: escala ventana completa y respeta máximo', async () => {
  const f = setup(); const cmd = f.command('window.zoomIn'); assert.equal(cmd.label, 'Zoom +');
  await cmd.action(); assert.equal(Number(f.document.documentElement.style.zoom), 1.1);
  for (let i = 0; i < 30; i++) await cmd.action(); assert.equal(Number(f.document.documentElement.style.zoom), 2);
  assert.equal((await f.key('+', { ctrlKey: true, shiftKey: true })).prevented, true);
});
test('CK-CAB-005 Zoom −: escala ventana completa y respeta mínimo', async () => {
  const f = setup(); const cmd = f.command('window.zoomOut'); assert.equal(cmd.label, 'Zoom −');
  await cmd.action(); assert.equal(Number(f.document.documentElement.style.zoom), 0.9);
  for (let i = 0; i < 30; i++) await cmd.action(); assert.equal(Number(f.document.documentElement.style.zoom), 0.5);
  assert.equal((await f.key('-', { ctrlKey: true })).prevented, true);
});
test('CK-CAB-005 Restablecer zoom: vuelve a 100% después de aumentar y reducir', async () => {
  const f = setup(); const cmd = f.command('window.resetZoom'); assert.equal(cmd.label, 'Restablecer zoom de la ventana');
  for (const id of ['window.zoomIn', 'window.zoomOut', 'window.zoomOut']) {
    await f.command(id).action(); await cmd.action(); assert.equal(Number(f.document.documentElement.style.zoom), 1);
  }
  await f.command('window.zoomOut').action(); await f.key('0', { ctrlKey: true });
  assert.equal(Number(f.document.documentElement.style.zoom), 1);
});

test('CK-CAB-005 Guardar todo: serializa invocaciones solapadas sin pisar la edición más reciente', async () => {
  const f = setup(); await f.open('a.txt', 'uno', true);
  const pending = [];
  f.editor.bridge.send = (method, args) => new Promise(resolve => {
    assert.equal(method, 'doc.save'); f.writes.push({ ...args });
    pending.push(() => { f.disk.set(args.path, args.content); resolve({ payload: { saved: true } }); });
  });
  const first = f.command('file.saveAll').action(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(pending.length, 1);
  f.edit('edición posterior');
  const second = f.command('file.saveAll').action(); await new Promise(resolve => setImmediate(resolve));
  assert.equal(pending.length, 1, 'no lanzar una escritura nueva mientras la anterior pueda pisarla');
  pending.shift()(); await first; await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.editor.isDirty('a.txt'), true, 'el primer guardado no limpia la edición posterior');
  assert.equal(pending.length, 1); pending.shift()(); await second;
  assert.equal(f.disk.get('a.txt'), 'edición posterior'); assert.equal(f.editor.isDirty('a.txt'), false);
});

test('CK-CAB-005 Ir a línea: no salta a otro archivo mientras el diálogo está abierto', async () => {
  const f = setup(); await f.open('a.txt', 'uno\ndos\ntres');
  let finish;
  // El doble permite demorar la respuesta del mismo prompt que abre el comando.
  f.prompts.push(new Promise(resolve => { finish = resolve; }));
  const navigation = f.command('editor.goToLine').action();
  await f.open('b.txt', 'solo una'); finish('3'); await navigation;
  assert.equal(f.state.lineNumber, 1); assert.equal(f.state.revealed, undefined);
  assert(f.notices.some(([m]) => m.includes('archivo')));
});
