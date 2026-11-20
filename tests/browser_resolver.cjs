// — resolvedor ÚNICO del navegador para las pruebas de UI (CDP).
//
// Orden de preferencia:
//   1. DEVAGENTS_TEST_BROWSER, si el archivo existe (si no existe se ignora y
//      se anota en el error final: nunca se usa a ciegas).
//   2. El Chromium headless de Playwright más reciente:
//      %LOCALAPPDATA%\ms-playwright\chromium_headless_shell-N\
//      chrome-headless-shell-win64\chrome-headless-shell.exe
//   3. Chrome o Edge instalados en sus rutas estándar.
// Si no hay ninguno, lanza un Error que lista TODAS las rutas probadas: una
// prueba de navegador sin navegador debe fallar a gritos, no saltarse.
//
// Los argumentos de `resolveBrowser` existen para probar el orden con rutas
// falsas (tests/browser_resolver_test.cjs) sin tocar el disco real.
const fs = require('node:fs');
const path = require('node:path');

const SHELL_REL = path.win32.join('chrome-headless-shell-win64', 'chrome-headless-shell.exe');

function playwrightCandidates(localAppData, readdir) {
  if (!localAppData) return [];
  const base = path.win32.join(localAppData, 'ms-playwright');
  let names = [];
  try { names = readdir(base); } catch (_) { return []; }
  return names
    .map(name => ({ name, m: /^chromium_headless_shell-(\d+)$/.exec(name) }))
    .filter(x => x.m)
    .sort((a, b) => Number(b.m[1]) - Number(a.m[1]))
    .map(x => path.win32.join(base, x.name, SHELL_REL));
}

function installedCandidates(env) {
  const roots = [env.PROGRAMFILES, env['PROGRAMFILES(X86)'], env.LOCALAPPDATA].filter(Boolean);
  const out = [];
  for (const r of roots) out.push(path.win32.join(r, 'Google', 'Chrome', 'Application', 'chrome.exe'));
  for (const r of roots) out.push(path.win32.join(r, 'Microsoft', 'Edge', 'Application', 'msedge.exe'));
  if (!env.PROGRAMFILES) out.push('C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe');
  if (!env['PROGRAMFILES(X86)']) out.push('C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe');
  return out;
}

function resolveBrowser(opts = {}) {
  const env = opts.env || process.env;
  const exists = opts.exists || (p => fs.existsSync(p));
  const readdir = opts.readdir || (p => fs.readdirSync(p));
  const tried = [];
  const attempt = (label, p) => {
    tried.push(`${label}: ${p}`);
    return exists(p) ? p : null;
  };
  if (env.DEVAGENTS_TEST_BROWSER) {
    const hit = attempt('DEVAGENTS_TEST_BROWSER', env.DEVAGENTS_TEST_BROWSER);
    if (hit) return hit;
  } else {
    tried.push('DEVAGENTS_TEST_BROWSER: (sin definir)');
  }
  const pw = playwrightCandidates(env.LOCALAPPDATA, readdir);
  if (!pw.length) tried.push(`Playwright: ninguna carpeta chromium_headless_shell-* en ${env.LOCALAPPDATA ? path.win32.join(env.LOCALAPPDATA, 'ms-playwright') : '(LOCALAPPDATA sin definir)'}`);
  for (const p of pw) { const hit = attempt('Playwright', p); if (hit) return hit; }
  for (const p of installedCandidates(env)) { const hit = attempt('Instalado', p); if (hit) return hit; }
  throw new Error(
    'No hay navegador para las pruebas de UI. Rutas probadas:\n  ' + tried.join('\n  ') +
    '\nDefine DEVAGENTS_TEST_BROWSER con un chrome.exe/chrome-headless-shell.exe existente o instala Chrome/Edge.'
  );
}

module.exports = { resolveBrowser };
