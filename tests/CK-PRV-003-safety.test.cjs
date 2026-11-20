const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const script = path.resolve(__dirname, '../tools/prv003_cabina.mjs');
const blockedNetwork = 'data:text/javascript,globalThis.fetch=()=>{throw Error("CDP reached before data isolation check")};';
for (const [name, data] of [
  ['missing', ''], ['relative', 'relative-prv003'],
  ['nonexistent', path.resolve(__dirname, '../.zig-cache/does-not-exist-prv003')],
  ['default', path.join(os.homedir(), 'AppData/Local/DevAgents')],
]) {
 test(`P1-b fail closed before CDP: ${name} BEATS_DATA_DIR`, () => {
    const child = spawnSync(process.execPath, ['--import', blockedNetwork, script], {
      env: { ...process.env, BEATS_DATA_DIR: data }, encoding: 'utf8', timeout: 5000, windowsHide: true,
    });
    assert.notEqual(child.status, 0);
    assert.match(child.stderr, /BEATS_DATA_DIR/);
    assert.doesNotMatch(child.stderr, /CDP reached/);
  });
}

test('P1-c watchdog cannot bypass restoration with process.exit', () => {
  assert.doesNotMatch(fs.readFileSync(script, 'utf8'), /process\.exit\(/);
});

test('P1-c timeout and interrupt attempt restoration; incomplete restoration is distinct failure', async () => {
  const { runWithRestoration } = await import(pathToFileURL(script).href);
  let restored = 0;
  await assert.rejects(runWithRestoration({
    run: () => new Promise(() => {}), restore: async () => { restored++; }, timeoutMs: 15,
  }), /exceeded/);
  assert.equal(restored, 1);
  const controller = new AbortController();
  const interrupted = runWithRestoration({
    run: () => new Promise(() => {}), restore: async () => { restored++; }, signal: controller.signal,
  });
  controller.abort(Error('SIGINT fixture'));
  await assert.rejects(interrupted, /SIGINT/);
  assert.equal(restored, 2);
  await assert.rejects(runWithRestoration({
    run: async () => {}, restore: () => new Promise(() => {}), restoreTimeoutMs: 15,
  }), error => error.exitCode === 2 && /restauración incompleta/.test(error.message));
  await assert.rejects(runWithRestoration({
    run: async () => {}, restore: async () => { throw Error('CDP disconnected during restore'); },
  }), error => error.exitCode === 2 && /restauración incompleta/.test(error.message));
});

test('P1-b accepts an existing isolated directory; canonical path does not overlap default', async () => {
  const { validateDataDir } = await import(pathToFileURL(script).href);
  const parent = path.resolve(__dirname, '../.zig-cache/prv003-verification');
  fs.mkdirSync(parent, { recursive: true });
  const isolated = fs.mkdtempSync(path.join(parent, 'data-safety-'));
  try {
    assert.equal(await validateDataDir(isolated), fs.realpathSync(isolated));
    await assert.rejects(validateDataDir(path.join(os.homedir(), 'AppData/Local')), /BEATS_DATA_DIR/);
    await assert.rejects(validateDataDir(path.join(os.homedir(), 'AppData/Local/DevAgents/child')), /BEATS_DATA_DIR/);
  } finally { fs.rmdirSync(isolated); }
});
