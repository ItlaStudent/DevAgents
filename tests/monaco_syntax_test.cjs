const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('../shell/webui/node_modules/typescript');

const root = process.env.DEVAGENTS_MONACO_SOURCE || path.resolve(__dirname, '../shell/webui/src');
const editorPath = path.join(root, 'editor/monaco_editor.ts');
const source = fs.readFileSync(editorPath, 'utf8');
let palette = {};
let assigned;
const globals = {
  console, window: { monaco: { editor: { setModelLanguage: (_, id) => { assigned = id; } } } },
  document: { documentElement: {} },
  getComputedStyle: () => ({ getPropertyValue: name => palette[name] || '' }),
};
const cache = new Map();
function load(file) {
  if (cache.has(file)) return cache.get(file).exports;
  const mod = { exports: {} }; cache.set(file, mod);
  let content = fs.readFileSync(file, 'utf8');
  if (file === editorPath) content += '\nexport const syntaxTestHooks = { applyBeatsTheme, loadMonaco };';
  const code = ts.transpileModule(content, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } }).outputText;
  vm.runInNewContext(`(function(require,module,exports){${code}\n})`, globals, { filename: file })(name => {
    assert(name.startsWith('.'), `Unexpected external import: ${name}`);
    return load(path.resolve(path.dirname(file), name + '.ts'));
  }, mod, mod.exports);
  return mod.exports;
}

let passed = 0, failed = 0;
async function check(name, action) {
  try { await action(); passed++; console.log('PASS ' + name); }
  catch (error) { failed++; console.error('FAIL ' + name + ': ' + error.message); }
}
const cases = [
  ['index.html', 'html'], ['x.HTM', 'html'], ['x.css', 'css'], ['x.js', 'javascript'],
  ['x.mjs', 'javascript'], ['x.cjs', 'javascript'], ['x.jsx', 'javascript'], ['x.ts', 'typescript'],
  ['x.tsx', 'typescript'], ['x.json', 'json'], ['x.md', 'markdown'], ['x.py', 'python'],
  ['x.zig', 'zig'], ['x.c', 'c'], ['x.cpp', 'cpp'], ['x.h', 'c'], ['x.hpp', 'cpp'],
  ['x.rs', 'rust'], ['x.go', 'go'], ['x.java', 'java'], ['x.sh', 'shell'], ['x.ps1', 'powershell'],
  ['x.yaml', 'yaml'], ['x.yml', 'yaml'], ['x.toml', 'toml'], ['x.sql', 'sql'], ['x.xml', 'xml'],
  ['x.unknown', 'plaintext'], ['x.constructor', 'plaintext'], ['README', 'plaintext'], ['C:\\project.html\\README', 'plaintext'],
];

async function run() {
  const { MonacoEditor, syntaxTestHooks } = load(editorPath);
  for (const [file, language] of cases) await check('openFile ' + file + ' -> ' + language, async () => {
    assigned = undefined;
    const label = {}, title = {};
    const editor = Object.create(MonacoEditor.prototype);
    Object.assign(editor, {
      filePath: '', content: '', buffers: new Map(), dirtyPaths: new Set(), viewStates: new Map(),
      container: { querySelector: selector => selector === '#editor-lang' ? label : title },
      monacoEd: { getModel: () => ({ updateOptions: () => {} }) },
      bridge: { send: async () => ({ content: 'synthetic source' }) },
      mostrarAvisoBinario: () => {}, setValue: () => {}, markDirty: () => {}, restoreViewState: () => {},
    });
    await editor.openFile(file);
    assert.equal(assigned, language, 'Editor model must use detected Monaco language');
    assert.equal(label.textContent, (language === 'cpp' ? 'c++' : language === 'plaintext' ? 'text' : language).toUpperCase(), 'Visible language must agree with model');
  });
  await check('AMD includes vendored basic-language contribution', () => {
    assert(/req\(\[\s*'vs\/editor\/editor.main',\s*'vs\/basic-languages\/monaco.contribution'\s*\]/.test(source), 'The AMD loader must request basic-language registrations');
  });
  await check('project language registration is idempotent and preserves existing providers', () => {
    const { registerProjectLanguages } = load(path.join(root, 'editor/monaco_language.ts'));
    const languages = new Map(), providers = new Map();
    const m = { languages: {
      getLanguages: () => [...languages.keys()].map(id => ({ id })),
      register: language => { assert(!languages.has(language.id)); languages.set(language.id, language); },
      setMonarchTokensProvider: (id, grammar) => { providers.set(id, grammar); },
    } };
    registerProjectLanguages(m); registerProjectLanguages(m);
    assert.deepEqual([...languages.keys()], ['zig', 'toml']);
    assert.equal(providers.size, 2);
    assert(providers.get('zig').tokenizer.root.some(rule => rule[1] === 'function'));
    assert(providers.get('zig').tokenizer.root.some(rule => rule[1] === 'type'));
    assert(providers.get('toml').tokenizer.multilineBasic);
  });
  for (const failure of ['script', 'require', 'amd']) await check('loader ' + failure + ' failure is visible and returns fallback', async () => {
    cache.delete(editorPath);
    const notices = [];
    const noticePath = path.join(root, 'design/notice.ts');
    const saved = cache.get(noticePath);
    cache.set(noticePath, { exports: { notice: (...args) => notices.push(args) } });
    const savedWindow = globals.window, savedDocument = globals.document;
    globals.window = { require: failure === 'require' ? undefined : Object.assign((_, success, reject) => reject(), { config: () => {} }) };
    globals.document = { createElement: () => ({}), head: { appendChild: element => failure === 'script' ? element.onerror() : element.onload() } };
    try {
      const hooks = load(editorPath).syntaxTestHooks;
      const promise = hooks.loadMonaco();
      assert.equal(hooks.loadMonaco(), promise, 'One shared loader promise');
      assert.equal(await promise, null);
      assert.equal(notices.length, 1, 'Failed syntax loading must not be silent');
      assert.match(notices[0][0], /editor simple/);
      assert.equal(notices[0][1], 'error');
    } finally {
      globals.window = savedWindow; globals.document = savedDocument;
      if (saved) cache.set(noticePath, saved); else cache.delete(noticePath);
      cache.delete(editorPath);
    }
  });
  const { themes } = load(path.join(root, 'design/theme_registry.ts'));
  for (const id of ['black', 'light']) await check('theme ' + id + ' differentiates syntax roles', () => {
    const theme = themes[id]; assert(theme, 'Theme exists');
    palette = Object.fromEntries(Object.entries(theme.colors).map(([name, value]) => ['--' + name.replace(/[A-Z]/g, letter => '-' + letter.toLowerCase()).replace(/(surface)(\d)/, '$1-$2'), value]));
    palette['--accent-2'] = theme.colors.accentHover;
    let definition;
    syntaxTestHooks.applyBeatsTheme({ languages: { getLanguages: () => [...new Set(cases.map(([, id]) => id))].map(id => ({ id })) }, editor: { defineTheme: (_, data) => { definition = data; }, setTheme: () => {} } });
    assert.equal(definition.base, theme.base === 'dark' ? 'vs-dark' : 'vs');
    assert.equal(definition.inherit, true);
    const roles = ['keyword', 'string', 'comment', 'number', 'type', 'function'];
    const colors = roles.map(token => definition.rules.find(rule => rule.token === token)?.foreground);
    assert(colors.every(value => /^[\da-f]{6}$/i.test(value)), 'Every syntax role has a valid hex color');
    assert.equal(new Set(colors).size, roles.length, 'Six syntax roles must remain distinguishable');
    assert.equal(definition.rules.find(rule => rule.token === 'function').foreground, theme.colors.info.slice(1), 'Function role must use the cabina info pigment');
    assert.equal(definition.rules.find(rule => rule.token === 'type').foreground, theme.colors.accentHover.slice(1), 'Type role must use the cabina secondary accent');
    assert.notEqual(definition.rules.find(rule => rule.token === 'tag').foreground, theme.colors.fg.slice(1));
    assert.notEqual(definition.rules.find(rule => rule.token === 'attribute.name').foreground, theme.colors.fg.slice(1));
    assert.equal(definition.rules.find(rule => rule.token === 'string.sql')?.foreground, definition.rules.find(rule => rule.token === 'string').foreground, 'Qualified upstream SQL string must preserve palette');
    assert.equal(definition.rules.find(rule => rule.token === 'keyword.type.ts')?.foreground, definition.rules.find(rule => rule.token === 'type').foreground, 'Built-in type keywords must use type color');
    for (const color of Object.values(definition.colors)) assert.match(color, /^#[\da-f]{6}([\da-f]{2})?$/i);
  });
  console.log(`MONACO SYNTAX ${passed}/${passed + failed} passed, ${failed} failed`);
  return failed === 0 ? 0 : 1;
}

if (require.main === module) run().then(code => { process.exitCode = code; }, error => { console.error(error); process.exitCode = 1; });
module.exports = { run, cases };
