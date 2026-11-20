const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

// El instalador copia shell/webui/vendor/monaco tal cual: el DOMPurify que
// importa es el que va incrustado en ese bundle, no el de node_modules.
// Con el vendor 0.56 venía 3.4.8 (1 crítica, 1 moderada en npm audit).
const MIN = [3, 4, 17];
const vendor = path.resolve(process.env.DEVAGENTS_MONACO_VENDOR || path.join(__dirname, '../vendor/monaco'));

function atLeast(version) {
  const parts = version.split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if (parts[i] !== MIN[i]) return parts[i] > MIN[i];
  }
  return true;
}

let embedded = null;
for (const name of fs.readdirSync(vendor).filter((file) => file.endsWith('.js'))) {
  const source = fs.readFileSync(path.join(vendor, name), 'utf8');
  if (!source.includes('removeAllHooks') || !source.includes('.sanitize')) continue;
  let version = /DOMPurify\.version\s*=\s*["'](\d+\.\d+\.\d+)["']/.exec(source)?.[1];
  if (!version) {
    // Vendor antiguo: la versión se asigna al principio de la factoría
    // minificada (`if(e.version="3.4.8",e.removed=[])`).
    const at = source.indexOf('removeAllHooks');
    const near = source.slice(Math.max(0, at - 24000), at);
    const re = /\.version\s*=\s*["'](\d+\.\d+\.\d+)["']/g;
    let match;
    while ((match = re.exec(near)) !== null) version = match[1];
  }
  if (version) embedded = { name, source, version };
}
assert(embedded, 'no embedded DOMPurify module found under shell/webui/vendor/monaco');
assert(
  atLeast(embedded.version),
  `${embedded.name} embeds DOMPurify ${embedded.version}; ${MIN.join('.')}+ is required because the installer ships this vendor folder`
);
for (const name of fs.readdirSync(vendor).filter((file) => file.endsWith('.js'))) {
  const source = fs.readFileSync(path.join(vendor, name), 'utf8');
  assert(!/3\.4\.(?:8|15)\b/.test(source), `${name} still contains vulnerable DOMPurify 3.4.8/3.4.15 markers`);
}
// T12 B6: integridad, sin red. El guion del parche deja en la marca de inicio
// la huella del dist/purify.cjs.js incrustado y la del cuerpo; aquí se
// recalcula la del cuerpo incrustado y, si el paquete local es de la misma
// versión, se rehace el cuerpo desde él y se comparan las dos huellas.
const crypto = require('node:crypto');
// Mismo cálculo que el guion: texto con fin de línea LF (git puede sacar CRLF).
const sha256 = (text) => crypto.createHash('sha256').update(text.replace(/\r\n/g, '\n'), 'utf8').digest('hex');
const EXPECTED_SOURCE_SHA256 = 'e89caec0717b7c1726e819b480133beaa1cdf7439c22fbfb753e5688be6922c3';
const EXPECTED_BODY_SHA256 = 'a4c7390590fff18d28e84d9fce26962220512e01a13a5264f0c859db03127085';
const BEGIN = '/*! monaco-dompurify-patch: DOMPurify ';
const END = '/*! monaco-dompurify-patch:end */';
const begin = embedded.source.indexOf(BEGIN);
assert(begin !== -1, `${embedded.name}: falta la marca de inicio del parche de DOMPurify`);
const end = embedded.source.indexOf(END, begin);
assert(end !== -1, `${embedded.name}: falta la marca de fin del parche de DOMPurify`);
const markerLine = embedded.source.slice(begin, embedded.source.indexOf('\n', begin));
const sourceHash = /source-sha256=([0-9a-f]{64})/.exec(markerLine)?.[1];
const bodyHash = /body-sha256=([0-9a-f]{64})/.exec(markerLine)?.[1];
assert(sourceHash && bodyHash, `${embedded.name}: la marca del parche no lleva source-sha256 ni body-sha256: ${markerLine}`);
assert.equal(sourceHash, EXPECTED_SOURCE_SHA256, 'source marker differs from the pinned DOMPurify source');
assert.equal(bodyHash, EXPECTED_BODY_SHA256, 'body marker differs from the pinned DOMPurify body');
const body = embedded.source.slice(embedded.source.indexOf('\n', begin) + 1, end);
assert.equal(sha256(body), EXPECTED_BODY_SHA256, `${embedded.name}: el DOMPurify incrustado cambió después de parchearlo (body-sha256 no coincide)`);
// Ruta directa: el paquete no exporta './package.json'.
const local = path.join(__dirname, '..', 'node_modules', 'dompurify', 'package.json');
const localVersion = fs.existsSync(local) ? JSON.parse(fs.readFileSync(local, 'utf8')).version : null;
if (localVersion === embedded.version) {
  const dist = fs.readFileSync(path.join(path.dirname(local), 'dist/purify.cjs.js'), 'utf8');
  assert.equal(sha256(dist), EXPECTED_SOURCE_SHA256, `el dist/purify.cjs.js local ${localVersion} no es el que se incrustó (source-sha256)`);
  console.log(`MONACO DOMPURIFY: el paquete local ${localVersion} tiene la misma huella que el incrustado`);
} else {
  console.log(`MONACO DOMPURIFY: paquete local ${localVersion ?? 'ausente'} distinto del incrustado ${embedded.version}; solo se comprueba body-sha256`);
}
console.log(`MONACO DOMPURIFY ${embedded.version} OK (>= ${MIN.join('.')}), body-sha256 ${bodyHash.slice(0, 12)}…`);