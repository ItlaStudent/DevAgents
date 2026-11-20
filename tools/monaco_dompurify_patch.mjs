#!/usr/bin/env node
// Replaces the DOMPurify module embedded in Monaco's AMD vendor bundle with a
// newer, self-contained copy from the dompurify package (>= 3.4.17).
//
// Monaco ships `vendor/monaco/*.js` pre-built; the installer copies that folder
// to dist, so patching node_modules alone changes nothing that travels. This
// script rewrites the DOMPurify factory inside the vendor file instead.
//
// Usage (from the repo root):
//   node tools/monaco_dompurify_patch.mjs
//   node tools/monaco_dompurify_patch.mjs --source <path/to/dompurify/dist/purify.cjs.js>
//   node tools/monaco_dompurify_patch.mjs --vendor <dir> --source <file>
//
// The default source is resolved from shell/webui's dompurify package, which
// must be >= 3.4.17 (package.json overrides pins it).
//
// It fails loudly when the embedded module cannot be located, so a Monaco
// upgrade that changes the bundle shape is noticed instead of silently skipped.
//
// T12 B6: the begin marker records `source-sha256=` (the dist/purify.cjs.js
// that was embedded) and `body-sha256=` (the exact text between the begin
// marker line and the end marker). shell/webui/tests/monaco_dompurify.test.cjs
// recomputes the body hash offline and, when the local package has the same
// version, rebuilds the body from it and compares source and body.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const MIN_DOMPURIFY = '3.4.17';
const BEGIN_MARK = '/*! monaco-dompurify-patch: DOMPurify ';
const END_MARK = '/*! monaco-dompurify-patch:end */';
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

function option(name, fallback) {
  const eq = process.argv.find((a) => a.startsWith(`--${name}=`));
  if (eq) return eq.slice(name.length + 3);
  const idx = process.argv.indexOf(`--${name}`);
  if (idx !== -1 && process.argv[idx + 1]) return process.argv[idx + 1];
  return fallback;
}

function parseVersion(text) {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(text.trim());
  if (!m) throw new Error(`Unsupported version: ${text}`);
  return m.slice(1).map(Number);
}

function isAtLeast(version, minimum) {
  const a = parseVersion(version);
  const b = parseVersion(minimum);
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] > b[i];
  }
  return true;
}

// Huellas sobre el texto con fin de línea LF: git puede sacar el vendor con CRLF.
const sha256 = (text) => crypto.createHash('sha256').update(text.replace(/\r\n/g, '\n'), 'utf8').digest('hex');

/** Hashes recorded in a begin marker, or null when the marker has none. */
export function markerHashes(markerLine) {
  const source = /source-sha256=([0-9a-f]{64})/.exec(markerLine);
  const body = /body-sha256=([0-9a-f]{64})/.exec(markerLine);
  return source && body ? { source: source[1], body: body[1] } : null;
}

/** Text between the begin marker line and the end marker (what body-sha256 covers). */
export function embeddedBody(src, regionStart, endIndex) {
  const lineEnd = src.indexOf('\n', regionStart);
  return src.slice(lineEnd + 1, endIndex);
}

function findEmbedded(vendorDir) {
  const files = fs.readdirSync(vendorDir).filter((f) => f.endsWith('.js')).sort();
  for (const name of files) {
    const file = path.join(vendorDir, name);
    const src = fs.readFileSync(file, 'utf8');

    const begin = src.indexOf(BEGIN_MARK);
    if (begin !== -1) {
      const end = src.indexOf(END_MARK, begin);
      if (end === -1) throw new Error(`${name}: patch start marker without end marker`);
      const version = /monaco-dompurify-patch: DOMPurify ([\d.]+)/.exec(src.slice(begin, begin + 80))[1];
      const markerLine = src.slice(begin, src.indexOf('\n', begin));
      const regionEnd = end + END_MARK.length;
      const after = src.slice(regionEnd);
      const call = /var\s+([A-Za-z_$][\w$]*)\s*=\s*([A-Za-z_$][\w$]*)\(\);/.exec(after);
      if (!call) throw new Error(`${name}: patched DOMPurify factory call not found after end marker`);
      return {
        name, file, src, version,
        patched: true,
        hashes: markerHashes(markerLine),
        body: embeddedBody(src, begin, end),
        factoryName: call[2],
        callName: call[1],
        regionStart: begin,
        regionEnd,
      };
    }

    const init = /if\(([A-Za-z_$][\w$]*)\.version\s*=\s*["'](\d+\.\d+\.\d+)["'],\1\.removed=\[\]/.exec(src);
    if (!init) continue;
    const [initText, instanceName, version] = init;
    const beforeInit = src.slice(0, init.index);
    const factoryDecl = /(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([A-Za-z_$][\w$]*)\s*=>\s*([A-Za-z_$][\w$]*)\s*\(\s*\2\s*\)/g;
    let match;
    let factoryName = null;
    while ((match = factoryDecl.exec(beforeInit)) !== null) factoryName = match[3];
    if (!factoryName) throw new Error(`${name}: DOMPurify version ${version} found but its factory name could not be derived`);
    const functionStart = beforeInit.lastIndexOf(`function ${factoryName}(){`);
    if (functionStart === -1) throw new Error(`${name}: function ${factoryName}(){ not found`);
    const after = src.slice(init.index);
    const callRe = new RegExp(`var\\s+([A-Za-z_$][\\w$]*)\\s*=\\s*${factoryName.replace(/[$]/g, '\\$')}\\(\\);`);
    const call = callRe.exec(after);
    if (!call) throw new Error(`${name}: call var <name> = ${factoryName}() not found after DOMPurify version ${version}`);
    const callIndex = init.index + call.index;
    if (src.slice(callIndex + call[0].length).length < 0) throw new Error('unreachable');
    return {
      name, file, src, version,
      patched: false,
      factoryName,
      callName: call[1],
      regionStart: functionStart,
      regionEnd: callIndex,
    };
  }
  return null;
}

function resolveSource(explicit) {
  if (explicit) {
    const p = path.resolve(explicit);
    if (fs.existsSync(p) && fs.statSync(p).isDirectory()) return path.join(p, 'dist/purify.cjs.js');
    if (!fs.existsSync(p)) throw new Error(`--source not found: ${p}`);
    return p;
  }
  const req = createRequire(path.join(repoRoot, 'shell/webui/package.json'));
  const pkgPath = req.resolve('dompurify/package.json');
  return path.join(path.dirname(pkgPath), 'dist/purify.cjs.js');
}

function sourceVersion(source) {
  const m = /DOMPurify\.version\s*=\s*["'](\d+\.\d+\.\d+)["']/.exec(source);
  if (!m) throw new Error('Source does not look like dompurify dist/purify.cjs.js (DOMPurify.version not found)');
  return m[1];
}

export function buildFactoryBody(source) {
  let code = source
    .replace(/^\s*\/\*![\s\S]*?\*\/\s*/, '')
    .replace(/\/\/# sourceMappingURL=.*\s*$/, '');
  code = code.replace(
    /var purify_default = createDOMPurify\(\);\s*module\.exports = purify_default;\s*$/,
    'return createDOMPurify;\n'
  );
  if (!/return createDOMPurify;/.test(code)) {
    throw new Error('Could not rewrite the dompurify dist tail (expected `var purify_default = createDOMPurify(); module.exports = purify_default;`)');
  }
  return code;
}

/** Exact text the patch places between the markers (license + factory). */
export function embeddedRegion(licenseComment, factoryName, body) {
  return `${licenseComment}\nconst ${factoryName}=(function(){\n${body}\n})();\n`;
}

export function licenseOf(source) {
  const license = /^\s*(\/\*![\s\S]*?\*\/)/.exec(source);
  return license ? license[1] : null;
}

function main() {
  const vendorDir = path.resolve(option('vendor', path.join(repoRoot, 'shell/webui/vendor/monaco')));
  if (!fs.existsSync(vendorDir)) throw new Error(`Vendor directory not found: ${vendorDir}`);

  const embedded = findEmbedded(vendorDir);
  if (!embedded) throw new Error(`No embedded DOMPurify module found in ${vendorDir}/*.js`);

  const required = option('minimum', MIN_DOMPURIFY);
  if (embedded.patched && isAtLeast(embedded.version, required) && embedded.hashes) {
    if (sha256(embedded.body) !== embedded.hashes.body) throw new Error(`${embedded.name}: embedded DOMPurify body does not match its body-sha256 (changed after patching)`);
    console.log(`OK  ${embedded.name}: DOMPurify ${embedded.version} already patched (>= ${required}), body-sha256 matches`);
    return;
  }

  const sourcePath = resolveSource(option('source'));
  const source = fs.readFileSync(sourcePath, 'utf8');
  const newVersion = sourceVersion(source);
  if (!isAtLeast(newVersion, required)) {
    throw new Error(`${sourcePath} has DOMPurify ${newVersion}; ${required}+ is required. Run \`npm install\` or pass --source.`);
  }
  const body = buildFactoryBody(source);
  // La licencia de DOMPurify (Apache-2.0 / MPL-2.0) viaja con el código.
  const license = /^\s*(\/\*![\s\S]*?\*\/)/.exec(source);
  if (!license || !/@license DOMPurify/.test(license[1])) {
    throw new Error(`${sourcePath} has no DOMPurify license header; refusing to embed it without its license`);
  }

  const regionBody = embeddedRegion(license[1], embedded.factoryName, body);
  const replacement =
    `${BEGIN_MARK}${newVersion} (begin) source-sha256=${sha256(source)} body-sha256=${sha256(regionBody)} */\n` +
    regionBody +
    `${END_MARK}`;
  if (embedded.patched && embedded.version === newVersion && !embedded.hashes) {
    // Adding the hashes to an existing patch: the body must be byte-identical.
    if (embedded.body.replace(/\r\n/g, '\n') !== regionBody.replace(/\r\n/g, '\n')) throw new Error(`${embedded.name}: the embedded DOMPurify ${embedded.version} is not byte-identical to ${sourcePath}`);
    console.log(`    embedded body is byte-identical to ${sourcePath}`);
  }

  const updated = embedded.src.slice(0, embedded.regionStart) + replacement + embedded.src.slice(embedded.regionEnd);
  // Compile without executing: catches a broken splice before writing 2.4 MB.
  try {
    new Function(updated);
  } catch (error) {
    throw new Error(`Patched vendor would not parse: ${error.message}`);
  }
  fs.writeFileSync(embedded.file, updated);
  console.log(`OK  ${embedded.name}: DOMPurify ${embedded.version} -> ${newVersion}`);
  console.log(`    source: ${sourcePath}`);
  console.log(`    factory: ${embedded.factoryName} (instance ${embedded.callName})`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`FAIL ${error.message}`);
    process.exit(1);
  }
}
