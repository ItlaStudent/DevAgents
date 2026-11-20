// 22-09: el editor no abre binarios como texto, las pestañas traen el editor
// al frente y el rojo de Monaco queda fuera de la paleta.
// node shell/webui/build_binary_test.mjs && node tests/editor_binary_test.cjs
const fs = require('fs');
const path = require('path');
const { pareceBinario } = require('../shell/webui/dist/binario.test.cjs');

let failed = 0;
function assert(name, cond, detail) {
  if (cond) {
    console.log(`  ok: ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${name} ${detail ? '-> ' + detail : ''}`);
  }
}

console.log('\n-- que es binario --');
// Cabecera real de SQLite: «SQLite format 3» y un NUL, luego la página 1.
const sqlite = 'SQLite format 3\u0000\u0010\u0000\u0001\u0001\u0000@  \u0000\u0000\u0000\u0002CREATE TABLE api_keys (id INTEGER)';
assert('una base SQLite es binaria', pareceBinario(sqlite));
// El caso de catalog.db: tras la cabecera, casi todo es esquema en texto
// plano. Por proporción de bytes raros pasaría por texto; lo delata el NUL.
const esquema = 'SQLite format 3\u0000' + 'CREATE TABLE models (id INTEGER PRIMARY KEY, model_name TEXT NOT NULL);\n'.repeat(60);
assert('una base cuyo arranque es casi todo esquema en texto también', pareceBinario(esquema));
assert('un PNG (NUL en la cabecera) es binario', pareceBinario('�PNG\r\n\u001a\n\u0000\u0000\u0000\rIHDR'));
const ruido = Array.from({ length: 400 }, (_, i) => (i % 3 === 0 ? '�' : 'a')).join('');
assert('bytes que no son UTF-8, sin NUL, también', pareceBinario(ruido));

console.log('\n-- que es texto --');
assert('un archivo vacío es texto', !pareceBinario(''));
assert('código con tabuladores y CRLF es texto', !pareceBinario('const a = 1;\r\n\tif (a) {\r\n\t\treturn;\r\n\t}\r\n'));
assert('español con tildes es texto', !pareceBinario('Canción, acción y ñandú: «comillas» — guion.\n'));
assert('una secuencia ANSI suelta no convierte un log en binario', !pareceBinario('\u001b[32mok\u001b[0m linea normal de un registro largo\n'.repeat(20)));
assert('un solo carácter de sustitución no basta', !pareceBinario('texto con un � perdido en medio de muchas palabras normales\n'));

console.log('\n-- colores que Monaco sabe leer --');
const { aHex } = require('../shell/webui/dist/monaco_color.test.cjs');
assert('rgba de --border pasa a #rrggbbaa', aHex('rgba(250,247,244,0.07)') === '#faf7f412', aHex('rgba(250,247,244,0.07)'));
assert('rgb sin alfa pasa a #rrggbb', aHex('rgb(10, 10, 10)') === '#0a0a0a');
assert('un hex se queda como está', aHex(' #c4553d ') === '#c4553d');
assert('un hex corto se expande', aHex('#abc') === '#aabbcc');
assert('lo que no es un color da null (y se usa el respaldo)', aHex('color-mix(in srgb, red, blue)') === null);

console.log('\n-- cableado (el aviso tiene llamador) --');
const raiz = path.join(__dirname, '..', 'shell', 'webui', 'src');
const editor = fs.readFileSync(path.join(raiz, 'editor', 'monaco_editor.ts'), 'utf8');
assert('openFile consulta pareceBinario', /pareceBinario\(text\)/.test(editor));
assert('guardar se niega sobre un binario', /if \(this\.binaryPath === this\.filePath\) return;/.test(editor));

const main = fs.readFileSync(path.join(raiz, 'main.ts'), 'utf8');
const seleccion = main.slice(main.indexOf('tabManager.onTabSelect('));
const cuerpo = seleccion.slice(0, seleccion.indexOf('});'));
assert('pulsar una pestaña trae el editor al frente', /router\.showEditor\(\)/.test(cuerpo), cuerpo);

const colores = editor.slice(editor.indexOf("    colors: {"), editor.indexOf('    },', editor.indexOf("    colors: {")));
assert('ningún color del tema de Monaco pasa sin normalizar (rgba = rojo puro)', colores.length > 100 && !/cssVar_\(/.test(colores), colores.slice(0, 80));

const estilos = fs.readFileSync(path.join(raiz, 'design', 'stylesheet.ts'), 'utf8');
assert('los bytes de control de Monaco usan la paleta, no #960000', /\.monaco-editor \.mtkcontrol \{[^}]*var\(--surface-3\) !important/.test(estilos));

console.log(`\n${failed === 0 ? 'TODAS LAS PRUEBAS DEL EDITOR PASARON' : failed + ' FALLOS'}`);
// E5.REL: language detection and theme regressions run in the normal suite.
const syntax = require('node:child_process').spawnSync(process.execPath, [path.join(__dirname, 'monaco_syntax_test.cjs')], { stdio: 'inherit', windowsHide: true });
if (syntax.error) console.error(syntax.error);
process.exit(failed === 0 && !syntax.error && syntax.status === 0 ? 0 : 1);
