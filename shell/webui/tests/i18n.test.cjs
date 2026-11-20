// 11-nov: diccionario inglés de la cabina (F3). Sin navegador.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const ts = require('typescript');
require.extensions['.ts'] = (module, filename) => {
  module._compile(ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }, fileName: filename,
  }).outputText, filename);
};
const { translate } = require('../src/i18n/i18n.ts');
const { EN_EXACT, EN_PATTERNS } = require('../src/i18n/en.ts');
assert.equal(translate('Enviar'), 'Send');
assert.equal(translate('  Modos  '), 'Modes', 'se recortan los espacios');
assert.equal(translate('Paso 2 de 4'), 'Step 2 of 4');
assert.equal(translate('Trabajó durante 6 s'), 'Worked for 6 s');
assert.equal(translate('Mostrar en selectores: OpenRouter / x'), 'Show in selectors: OpenRouter / x');
assert.equal(translate('HOY · 19'), 'Today · 19');
assert.equal(translate('Responde solo: tres'), null, 'el texto del usuario no tiene traducción');
assert.equal(translate('gpt-6.1-sol'), null);
assert(Object.keys(EN_EXACT).length > 400, 'el diccionario cubre la cabina');
for (const [k, v] of Object.entries(EN_EXACT)) assert(v && v !== k || /^(Auto|Hooks|Manual|Monitor|Plan|Plugins|Skills|Terminal|Personal)$/.test(k), `traducción vacía o idéntica: ${k}`);
for (const [re] of EN_PATTERNS) assert(re instanceof RegExp && re.source.startsWith('^') && re.source.endsWith('$'), `patrón sin anclar: ${re}`);
console.log(`I18N: ${Object.keys(EN_EXACT).length} frases y ${EN_PATTERNS.length} patrones PASS`);
