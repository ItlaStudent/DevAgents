'use strict';
// F6 (10-nov): atajos personalizables. Prueba de lógica sin
// navegador: se transpila app/keybindings.ts y se ejecuta con un window y un
// document mínimos.
const assert = require('assert');
const fs = require('fs');
const path = require('path');

module.exports = async function keybindings() {
  const ts = require('../node_modules/typescript');
  const src = fs.readFileSync(path.join(__dirname, '..', 'src/app/keybindings.ts'), 'utf8');
  const out = ts.transpileModule(src, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 } });
  const store = new Map();
  const listeners = [];
  const fakeWindow = { localStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)) } };
  const fakeDocument = { body: { dataset: {} }, addEventListener: (type, fn, capture) => listeners.push({ type, fn, capture }) };
  const mod = { exports: {} };
  new Function('module', 'exports', 'window', 'document', out.outputText)(mod, mod.exports, fakeWindow, fakeDocument);
  const kb = mod.exports;

  // Normalización.
  assert.equal(kb.normalizeCombo('shift+ctrl+s'), 'Ctrl+Shift+S');
  assert.equal(kb.normalizeCombo('Ctrl+='), 'Ctrl++');
  assert.equal(kb.normalizeCombo('Ctrl+Shift++'), 'Ctrl++', 'el + no arrastra Shift');
  assert.equal(kb.normalizeCombo('alt+arrowleft'), 'Alt+←');
  assert.equal(kb.normalizeCombo('Ctrl+,'), 'Ctrl+,');
  const ev = (key, m = {}) => ({ key, ctrlKey: !!m.ctrl, altKey: !!m.alt, shiftKey: !!m.shift, metaKey: false, target: null, preventDefault() { this.prevented = true; }, stopImmediatePropagation() {} });
  assert.equal(kb.comboFromEvent(ev('s', { ctrl: true, shift: true })), 'Ctrl+Shift+S');
  assert.equal(kb.comboFromEvent(ev('+', { ctrl: true, shift: true })), 'Ctrl++');
  assert.equal(kb.comboFromEvent(ev('Control', { ctrl: true })), '', 'un modificador solo no es combinación');
  assert.ok(kb.isAssignable('Alt+Z') && kb.isAssignable('F5') && !kb.isAssignable('S') && !kb.isAssignable('Shift+S'));

  // Registro, cambio, conflicto y restablecer.
  const fired = [];
  kb.registerBindableCommands([
    { id: 'a', label: 'Guardar todo', shortcut: 'Ctrl+Shift+S', action: () => fired.push('a') },
    { id: 'b', label: 'Ir a línea', shortcut: 'Ctrl+G', action: () => fired.push('b') },
  ]);
  assert.equal(kb.effectiveShortcut('a'), 'Ctrl+Shift+S');
  const displaced = kb.setShortcut('a', 'Ctrl+G');
  assert.equal(displaced, 'b', 'quien tenía la combinación la pierde');
  assert.equal(kb.effectiveShortcut('a'), 'Ctrl+G');
  assert.equal(kb.effectiveShortcut('b'), '', 'b se queda sin atajo');
  assert.ok(kb.isCustomized('a') && kb.isCustomized('b'));
  assert.ok(store.get(kb.KEYBINDINGS_STORAGE_KEY).includes('Ctrl+G'), 'se guarda en este equipo');

  // Despacho único: la combinación nueva ejecuta el comando; la vieja ya no.
  kb.installKeybindings(fakeDocument);
  const keydown = listeners.find((l) => l.type === 'keydown');
  assert.ok(keydown && keydown.capture === true, 'despachador en fase de captura');
  const e1 = ev('g', { ctrl: true }); keydown.fn(e1);
  assert.deepEqual(fired, ['a']); assert.ok(e1.prevented);
  keydown.fn(ev('s', { ctrl: true, shift: true }));
  assert.deepEqual(fired, ['a'], 'el atajo anterior ya no hace nada');
  fakeDocument.body.dataset.recordingShortcut = '1';
  keydown.fn(ev('g', { ctrl: true }));
  assert.deepEqual(fired, ['a'], 'mientras se graba un atajo no se despacha');
  delete fakeDocument.body.dataset.recordingShortcut;

  kb.resetShortcut();
  assert.equal(kb.effectiveShortcut('a'), 'Ctrl+Shift+S');
  assert.equal(kb.effectiveShortcut('b'), 'Ctrl+G');
  console.log('PASS CK-PUB-009 F6: atajos normalizados, cambiables con conflicto resuelto, guardados, despacho único y restablecer.');
};

if (require.main === module) module.exports().catch((e) => { console.error(e); process.exit(1); });
