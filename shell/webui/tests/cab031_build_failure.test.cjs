// Un error de empaquetado debe rechazar y cerrar el navegador del arnés.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const { spawn, spawnSync } = require('node:child_process');

test('CAB031: un fallo de esbuild termina con exit 1 sin colgar Chromium', async () => {
  const script = `
    const esbuild = require('esbuild');
    require.cache[require.resolve('esbuild')].exports = {
      ...esbuild, build: async () => { throw Error('CAB031_BUILD_FAILURE_SENTINEL'); }
    };
    require('./cab031.test.cjs')().catch(error => {
      console.error(error); process.exitCode = 1;
    });
  `;
  const child = spawn(process.execPath, ['-e', script], {
    cwd: __dirname, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'],
  });
  let output = '', timedOut = false;
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  const timer = setTimeout(() => {
    timedOut = true;
    if (process.platform === 'win32') {
      const killed = spawnSync('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true, encoding: 'utf8', timeout: 10000 });
      output += killed.stdout + killed.stderr;
    } else child.kill('SIGKILL');
  }, 20000);
  const code = await new Promise((resolve, reject) => {
    child.once('error', reject);
    child.once('exit', resolve);
  }).finally(() => clearTimeout(timer));
  assert.match(output, /CAB031_BUILD_FAILURE_SENTINEL/);
  assert.equal(timedOut, false, `El fallo de build dejó recursos abiertos:\n${output}`);
  assert.equal(code, 1, output);
});
