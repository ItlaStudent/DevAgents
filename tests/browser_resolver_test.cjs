// — prueba del resolvedor con rutas FALSAS inyectadas (no toca el disco real).
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { resolveBrowser } = require('./browser_resolver.cjs');

const LAD = 'C:\\fake\\Local';
const PW = n => `${LAD}\\ms-playwright\\chromium_headless_shell-${n}\\chrome-headless-shell-win64\\chrome-headless-shell.exe`;
const CHROME = 'C:\\fake\\PF\\Google\\Chrome\\Application\\chrome.exe';
const EDGE = 'C:\\fake\\PF86\\Microsoft\\Edge\\Application\\msedge.exe';
const baseEnv = { LOCALAPPDATA: LAD, PROGRAMFILES: 'C:\\fake\\PF', 'PROGRAMFILES(X86)': 'C:\\fake\\PF86' };
const fake = (files, dirs = ['chromium_headless_shell-1200', 'chromium_headless_shell-1243', 'chromium-1243', 'ffmpeg-1011']) => ({
  exists: p => files.includes(p),
  readdir: p => { assert.equal(p, `${LAD}\\ms-playwright`); return dirs; },
});

// 1. La variable manda si el archivo existe, aunque haya Playwright y Chrome.
assert.equal(resolveBrowser({ env: { ...baseEnv, DEVAGENTS_TEST_BROWSER: 'D:\\mi\\chrome.exe' }, ...fake(['D:\\mi\\chrome.exe', PW(1243), CHROME]) }), 'D:\\mi\\chrome.exe');
// 2. Sin variable: Playwright más reciente (1243 antes que 1200) antes que Chrome/Edge.
assert.equal(resolveBrowser({ env: baseEnv, ...fake([PW(1200), PW(1243), CHROME, EDGE]) }), PW(1243));
assert.equal(resolveBrowser({ env: baseEnv, ...fake([PW(1200), CHROME]) }), PW(1200), 'cae a la versión anterior si la reciente no tiene el exe');
// 3. Variable con archivo inexistente: cae al siguiente (Playwright).
assert.equal(resolveBrowser({ env: { ...baseEnv, DEVAGENTS_TEST_BROWSER: 'D:\\no\\existe.exe' }, ...fake([PW(1243), CHROME]) }), PW(1243));
// 4. Sin Playwright: Chrome antes que Edge; sin Chrome, Edge.
assert.equal(resolveBrowser({ env: baseEnv, ...fake([CHROME, EDGE]) }), CHROME);
assert.equal(resolveBrowser({ env: baseEnv, ...fake([EDGE]) }), EDGE);
// 5. Sin carpeta de Playwright (readdir lanza) tampoco rompe.
assert.equal(resolveBrowser({ env: baseEnv, exists: p => p === CHROME, readdir: () => { throw new Error('ENOENT'); } }), CHROME);
// 6. Nada disponible: error claro con la lista de rutas probadas, incluida la variable inexistente.
assert.throws(
  () => resolveBrowser({ env: { ...baseEnv, DEVAGENTS_TEST_BROWSER: 'D:\\no\\existe.exe' }, ...fake([]) }),
  e => {
    for (const s of ['No hay navegador', 'DEVAGENTS_TEST_BROWSER: D:\\no\\existe.exe', PW(1243), PW(1200), CHROME, EDGE, 'Define DEVAGENTS_TEST_BROWSER']) {
      assert.ok(e.message.includes(s), `el error menciona ${s}\n${e.message}`);
    }
    return true;
  }
);
assert.throws(() => resolveBrowser({ env: {}, exists: () => false, readdir: () => [] }), /sin definir[\s\S]*LOCALAPPDATA sin definir/);
// 7. Contrato de uso: las pruebas de navegador lo usan y ninguna conserva la ruta de Puppeteer.
const root = path.resolve(__dirname, '..');
for (const f of ['tests/CK-COMP-007-ui.cjs', 'tests/monaco_browser_test.cjs', 'tests/right_cards_ui_test.cjs', 'tests/session_archive_ui_test.cjs',
  'shell/webui/tests/activity_collapse.test.cjs', 'shell/webui/tests/activity_panel.test.cjs', 'shell/webui/tests/cabina_ux_browser.cjs',
  'shell/webui/tests/settings_redesign.test.cjs', 'shell/webui/tests/contexto_compositor.test.cjs', 'shell/webui/tests/code_copy_file_actions.test.cjs']) {
  const full = path.join(root, f);
  if (!fs.existsSync(full)) continue;
  const src = fs.readFileSync(full, 'utf8');
  assert.ok(/browser_resolver\.cjs/.test(src) && /resolveBrowser\(\)/.test(src), `${f} usa resolveBrowser()`);
  assert.ok(!/puppeteer/i.test(src), `${f} no conserva la ruta de Puppeteer`);
  assert.ok(!/chrome\.exe/.test(src), `${f} no fija chrome.exe`);
}
console.log('browser_resolver: 7 grupos PASS (orden, variable inexistente, error con lista, contrato de uso)');
