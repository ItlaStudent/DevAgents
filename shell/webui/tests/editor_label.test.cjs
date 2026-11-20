const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const path = require('node:path');

const source = process.argv.includes('--baseline')
  ? require('node:child_process').execFileSync('git', ['show', 'HEAD:shell/webui/src/editor/monaco_editor.ts'], { encoding: 'utf8' })
  : fs.readFileSync(path.join(__dirname, '../src/editor/monaco_editor.ts'), 'utf8');
test('fallback code textarea has an explicit accessible name', () => {
  const tag = source.match(/<textarea\b[^>]*\bid="code-textarea"[^>]*>/)?.[0];
  assert.match(tag, /aria-label="Editor de código"/);
});
test('Monaco input receives the same accessible name when assigned its historical id', () => {
  const branch = source.slice(source.indexOf("const input = host.querySelector('textarea.ime-text-area"), source.indexOf('this.setValue(this.content);', source.indexOf("const input = host.querySelector('textarea.ime-text-area")));
  const input = { setAttribute(name, value) { this[name] = value; } };
  new Function('host', branch)({ querySelector() { return input; } });
  assert.equal(input.id, 'code-textarea');
  assert.equal(input['aria-label'], 'Editor de código');
});
