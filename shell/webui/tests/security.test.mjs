import assert from 'node:assert/strict';
import test from 'node:test';
import { readFileSync, readdirSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../', import.meta.url));
const bundle = await build({
  stdin: { contents: `
    export * from './src/design/html';
    export * from './src/design/markdown';
    export * from './src/editor/highlight';
    export * from './src/terminal/xterm_terminal';
    export * from './src/panes/verification_panel';
    export * from './src/components/command_palette';
    export * from './src/components/conversation_control';
    export * from './src/editor/monaco_editor';
  `, resolveDir: root, loader: 'ts' },
  bundle: true, write: false, format: 'cjs', platform: 'node', target: 'node20',
});
const exports = {};
const module = { exports };
vm.runInThisContext(`(function(exports, module) {${bundle.outputFiles[0].text}\n})`, {
  filename: 'security-ui-test.cjs',
})(exports, module);
const ui = module.exports;
const payloads = [
  ['seis caracteres', '&<>"\'`', '&amp;&lt;&gt;&quot;&#39;&#96;'],
  ['script', '<script>alert(1)</script>', '&lt;script&gt;alert(1)&lt;/script&gt;'],
  ['imagen', '<img src=x onerror=alert(1)>', '&lt;img src=x onerror=alert(1)&gt;'],
  ['atributo doble', '" autofocus onfocus="alert(1)', '&quot; autofocus onfocus=&quot;alert(1)'],
  ['atributo simple', "' onmouseover='alert(1)", '&#39; onmouseover=&#39;alert(1)'],
  ['backtick', '` onload=alert(1)', '&#96; onload=alert(1)'],
  ['entidad', '&#x3c;script&#x3e;', '&amp;#x3c;script&amp;#x3e;'],
  ['svg', '</textarea><svg/onload=alert(1)>', '&lt;/textarea&gt;&lt;svg/onload=alert(1)&gt;'],
];
const plain = html => html.replace(/<[^>]*>/g, '').replace(/&(amp|lt|gt|quot|#39|#96);/g,
  (_, entity) => ({ amp: '&', lt: '<', gt: '>', quot: '"', '#39': "'", '#96': '`' })[entity]);
const assertNoInjectedTags = html => assert.doesNotMatch(html, /<\/?(?:script|img|svg|textarea)\b/i);

test('escape central: texto y atributos conservan datos e impiden salir del contexto', async t => {
  for (const [name, raw, escaped] of payloads) await t.test(name, () => {
    assert.equal(ui.escapeText(raw), escaped);
    assert.equal(ui.escapeAttribute(raw), escaped);
    assert.equal(plain(escaped), raw);
    assert.doesNotMatch(escaped, /[<>"'`]/);
  });
  assert.equal(ui.escapeText(null), '');
  assert.equal(ui.escapeText(undefined), '');
  assert.equal(ui.escapeText(42), '42');
});

test('salida del modelo: Markdown escapa hojas, conserva vallas y formatos', () => {
  for (const [, raw] of payloads) assertNoInjectedTags(ui.renderMarkdown(raw));
  assert.equal(ui.renderMarkdown('`x < y`'), '<p><code>x &lt; y</code></p>');
  assert.equal(ui.renderMarkdown('**seguro**'), '<p><strong>seguro</strong></p>');
  assert.equal(ui.renderMarkdown('> <img src=x>'), '<blockquote>&lt;img src=x&gt;</blockquote>');
  const code = 'echo "<img src=x>" & \'`\'';
  const html = ui.renderMarkdown('```bash\n' + code + '\n```');
  assert.match(html, /md-cmd__run/);
  // / (b6bd3ee6, src/design/markdown.ts:103): el bloque
  // con valla pasa por highlight(); el <code> lleva spans tok-* propios, así que
  // ya no es escapeText(code) literal. Se exige lo mismo de seguridad: solo
  // spans con clase fija, cada carácter peligroso escapado y el texto intacto.
  const inner = html.match(/<code>([\s\S]*)<\/code><\/pre>$/)?.[1];
  assert.ok(inner !== undefined, html);
  assert.doesNotMatch(inner.replace(/<span class="tok-[a-z]+">|<\/span>/g, ''), /[<>"'`]/);
  assert.equal(plain(inner), code);
  assert.match(inner, /&quot;&lt;img src=x&gt;&quot;/);
  assert.match(inner, /&#39;&#96;&#39;/);
  assertNoInjectedTags(html);
  assert.equal(ui.renderMarkdown('|'), '<p>|</p>');
  assert.equal(ui.renderMarkdown('```unusual-language'), '<p>&#96;&#96;&#96;unusual-language</p>');
});

test('contenido de archivos: resaltado conserva entidades y texto en cada lenguaje', () => {
  for (const lang of ['text', 'json', 'typescript', 'cpp', 'python', 'zig', 'markdown', 'bash', 'powershell']) {
    for (const [, raw] of payloads) {
      const html = ui.highlight(raw, lang);
      assertNoInjectedTags(html);
      assert.equal(plain(html), raw, lang);
    }
  }
  assert.match(ui.highlight('{"key":"value"}', 'json'), /tok-key/);
  assert.match(ui.highlight('{"key":"value"}', 'json'), /tok-str/);
});

test('salida de procesos: ANSI solo produce spans propios y colores numéricos', () => {
  for (const [, raw] of payloads) {
    const state = { fg: null, bg: null, bold: false, dim: false, italic: false, underline: false };
    const result = ui.ansiToHtml('\x1b[31m' + raw, state);
    assertNoInjectedTags(result.html);
    assert.equal(plain(result.html), raw);
  }
});

test('ledger y paleta: datos externos pasan por escape central', () => {
  const raw = payloads[2][1];
  const list = { innerHTML: '', querySelectorAll: () => [] };
  const panel = Object.create(ui.VerificationPanel.prototype);
  panel.container = { querySelector: () => list };
  panel.verifications = [{ item: raw, evidencePath: raw, verdict: raw }];
  panel.renderVerifications();
  assertNoInjectedTags(list.innerHTML);
  assert.match(list.innerHTML, /&lt;img/);
  const control = Object.create(ui.ConversationControl.prototype);
  const plan = { innerHTML: '', querySelector: () => null };
  control.renderEditablePlan(plan, 1, [{ description: payloads[3][1] }]);
  assert.match(plan.innerHTML, /value="&quot; autofocus onfocus=&quot;alert\(1\)"/);
  panel.ledgerBlocks = [{ index: raw, action: raw, model: raw, hash: raw, prevHash: raw }];
  panel.renderLedger();
  assertNoInjectedTags(list.innerHTML);
  const palette = Object.create(ui.CommandPalette.prototype);
  palette.listElem = list;
  palette.filteredCommands = [{ label: raw, category: raw, shortcut: raw }];
  palette.selectedIndex = 0;
  palette.renderList();
  assertNoInjectedTags(list.innerHTML);
  assert.match(list.innerHTML, /&lt;img/);
});

test('Guardar como: cancelación, token de un solo envío y fallo preservan el borrador', async () => {
  // Se prueba el controlador real; sin construir Monaco ni tocar archivos.
  const originalDocument = globalThis.document;
  const originalRaf = globalThis.requestAnimationFrame;
  const originalWindow = globalThis.window;
  const events = [];
  globalThis.document = { dispatchEvent: event => events.push(event) };
  globalThis.requestAnimationFrame = () => {};
  globalThis.window = { setTimeout: () => 0 };
  try {
    for (const outcome of ['cancel', 'saved', 'failed']) {
      const cancelled = outcome === 'cancel';
      const calls = [];
      const editor = Object.create(ui.MonacoEditor.prototype);
      Object.assign(editor, { filePath: 'C:/original.txt', binaryPath: null, content: 'draft',
        buffers: new Map(), container: { querySelector: () => null }, dirtyPaths: new Set(['C:/original.txt']) });
      editor.bridge = { send: async (kind, payload) => {
        calls.push({ kind, payload });
        if (kind === 'doc.save' && outcome === 'failed') throw new Error('write failed');
        return { payload: { cancelled, path: 'C:/original.txt', saveToken: 'once' } };
      } };
      // Misma ruta evita el toast DOM; se sustituye el DOM solo para ese aviso.
      const notices = { children: [], style: {}, appendChild: () => {}, setAttribute: () => {} };
      globalThis.document.getElementById = () => notices;
      globalThis.document.createElement = () => ({ style: {}, appendChild: () => {}, setAttribute: () => {}, remove: () => {} });
      globalThis.document.createTextNode = () => ({});
      await editor.saveCurrentFileAs();
      assert.equal(calls.length, cancelled ? 1 : 2);
      if (!cancelled) {
        assert.deepEqual(calls[1], { kind: 'doc.save', payload: {
          path: 'C:/original.txt', content: 'draft', force: true, saveToken: 'once' } });
        assert.equal(editor.dirtyPaths.size, outcome === 'failed' ? 1 : 0);
      } else assert.equal(editor.dirtyPaths.size, 1);
    }
  } finally {
    globalThis.document = originalDocument;
    globalThis.requestAnimationFrame = originalRaf;
    globalThis.window = originalWindow;
  }
});

test('CSP: scripts solo de archivos del origen y styles inline justificados', () => {
  const html = readFileSync(resolve(root, 'public/index.html'), 'utf8');
  const csp = html.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)[1];
  const scripts = csp.split(';').find(value => value.trim().startsWith('script-src'));
  assert.doesNotMatch(scripts, /unsafe-inline|unsafe-eval|data:|blob:/);
  const fonts = csp.split(';').find(value => value.trim().startsWith('font-src'));
  assert.equal(fonts.trim(), "font-src 'self' https://devagents.local data:",
    'Monaco bundled Codicon is a data font; allow it only in the font directive');
  for (const directive of ["base-uri 'none'", "form-action 'none'"])
    assert(csp.split(';').some(value => value.trim() === directive), `${directive} missing from CSP`);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/i);
  assert.match(html, /Monaco crea estilos dinámicos/);
});

test('no quedan copias de escapadores locales', () => {
  const visit = folder => {
    for (const entry of readdirSync(folder, { withFileTypes: true })) {
      const path = resolve(folder, entry.name);
      if (entry.isDirectory()) visit(path);
      else if (entry.name.endsWith('.ts')) {
        assert.doesNotMatch(readFileSync(path, 'utf8'), /(?:function|private)\s+(?:esc|escapeHtml)\s*\(/, path);
      }
    }
  };
  visit(resolve(root, 'src'));
});
