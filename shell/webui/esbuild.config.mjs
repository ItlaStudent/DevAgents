import { execFileSync } from 'node:child_process';
import * as esbuild from 'esbuild';
import * as fs from 'fs';
import * as path from 'path';

const outDir = path.resolve('dist');
const version = fs.readFileSync('../../core/src/root.zig', 'utf8').match(/pub const VERSION = "([^"]+)";/)?.[1];
if (!version) throw new Error('Missing canonical core.VERSION');
function sourceRevision() {
  try {
    return execFileSync('git', ['rev-parse', '--short=12', 'HEAD'], {
      encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    const manifest = '../../DEVAGENTS-REVISION';
    if (!fs.existsSync(manifest)) return '';
    const revision = fs.readFileSync(manifest, 'utf8').trim();
    if (!/^[0-9a-f]{12}$/i.test(revision)) throw new Error('Invalid DEVAGENTS-REVISION');
    return revision;
  }
}
let identity = process.env.DEVAGENTS_BUILD_IDENTITY;
if (!identity) {
  const hash = sourceRevision();
  identity = `${version}${hash ? '+' + hash : ''}/abi1.bus1.ui1`;
}


if (!fs.existsSync(outDir)) {
  fs.mkdirSync(outDir, { recursive: true });
}

// public/ entero: index.html y brand/ (los recortes del logo real que genera
// tools/brand/generate_brand_assets.py). Copiar solo index.html dejaba la
// marca sin servir.
fs.cpSync(path.resolve('public'), outDir, { recursive: true });

// Dependencias vendorizadas (ADR-B012 §4): Monaco AMD (min/vs) y xterm.js UMD
// se sirven tal cual desde vendor/ — el editor/terminal reales son parte del
// paquete offline, no de la red.
fs.cpSync(path.resolve('vendor'), path.join(outDir, 'vendor'), { recursive: true });

await esbuild.build({
  tsconfigRaw: {},
  entryPoints: ['src/main.ts'],
  banner: { js: `/* DevAgents build: ${identity} */` },
  define: { __DEVAGENTS_BUILD_IDENTITY__: JSON.stringify(identity) },
  bundle: true,
  outfile: path.join(outDir, 'bundle.js'),
  target: 'chrome110',
  minify: true,
  sourcemap: false,
  format: 'iife',
});

fs.writeFileSync(path.join(outDir, 'version.json'), JSON.stringify({identity}) + '\n');

console.log('WebUI bundle built successfully in shell/webui/dist');

const rootDistDir = path.resolve('../../dist');
if (fs.existsSync(rootDistDir)) {
  fs.copyFileSync(path.join(outDir, 'index.html'), path.join(rootDistDir, 'index.html'));
  fs.copyFileSync(path.join(outDir, 'bundle.js'), path.join(rootDistDir, 'bundle.js'));
  fs.copyFileSync(path.join(outDir, 'version.json'), path.join(rootDistDir, 'version.json'));
  fs.cpSync(path.join(outDir, 'brand'), path.join(rootDistDir, 'brand'), { recursive: true });
  console.log('Synced WebUI bundle to root dist directory');
}
