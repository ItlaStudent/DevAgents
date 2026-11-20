// D5: prueba del parser ANSI SGR de la terminal. node tests/ansi_test.cjs
//
// Por que existe: el parser se entrego el 2026-08-15 y la auditoria del mismo
// dia anoto «util y sin una sola prueba». Un parser sin prueba es el sitio
// clasico donde un `cat` de un binario acaba inyectando HTML en la ventana.
const { ansiToHtml } = require('../shell/webui/dist/ansi.test.cjs');

let failed = 0;
function assert(name, cond, detail) {
  if (cond) {
    console.log(`  ok: ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${name} ${detail ? '-> ' + detail : ''}`);
  }
}

const ESC = '\x1b';
const nuevo = () => ({ fg: null, bg: null, bold: false, dim: false, italic: false, underline: false });

console.log('\n-- texto plano --');
{
  const r = ansiToHtml('hola mundo', nuevo());
  assert('sin escapes sale tal cual', r.html === 'hola mundo', r.html);
}

console.log('\n-- lo que NO puede pasar: inyeccion de HTML --');
{
  // Un `cat` de un archivo con etiquetas, o un mensaje de error de un
  // compilador con generics. Si esto no se escapa, la terminal ejecuta script
  // del contenido que imprime cualquier proceso hijo.
  const r = ansiToHtml('<script>alert(1)</script> & "comillas"', nuevo());
  assert('la etiqueta se escapa', r.html.indexOf('<script>') === -1, r.html);
  assert('queda el texto escapado', r.html.indexOf('&lt;script&gt;') !== -1, r.html);
  assert('el ampersand se escapa primero', r.html.indexOf('&amp;') !== -1, r.html);
  assert('las comillas tambien', r.html.indexOf('&quot;') !== -1, r.html);
}
{
  // Y el escape tiene que sobrevivir DENTRO de un tramo con color, que es
  // donde se construye un atributo style="..." a mano.
  const r = ansiToHtml(`${ESC}[31m<b>rojo</b>${ESC}[0m`, nuevo());
  assert('escapado tambien dentro de un span', r.html.indexOf('<b>') === -1, r.html);
  assert('y el span sigue estando', r.html.indexOf('<span style=') === 0, r.html);
}

console.log('\n-- color --');
{
  const r = ansiToHtml(`${ESC}[31mrojo${ESC}[0m normal`, nuevo());
  assert('31 pinta de danger', r.html.indexOf('color:var(--danger)') !== -1, r.html);
  assert('0 devuelve el estado a limpio', r.state.fg === null, JSON.stringify(r.state));
  assert('el texto tras el reset sale sin span', r.html.endsWith(' normal'), r.html);
}
{
  const r = ansiToHtml(`${ESC}[1;32mverde negrita${ESC}[0m`, nuevo());
  assert('atributos combinados en una sola secuencia', r.html.indexOf('font-weight:bold') !== -1 && r.html.indexOf('color:var(--success)') !== -1, r.html);
}
{
  const r = ansiToHtml(`${ESC}[41mfondo${ESC}[49m`, nuevo());
  assert('41 pinta el fondo', r.html.indexOf('background-color:') !== -1, r.html);
  assert('49 lo quita', r.state.bg === null);
}

console.log('\n-- el estado sobrevive entre lecturas (la terminal llega a trozos) --');
{
  // Esto es lo que distingue un parser de terminal de un reemplazo de texto:
  // la tuberia entrega el color en una lectura y el texto en la siguiente.
  const estado = nuevo();
  const a = ansiToHtml(`${ESC}[33m`, estado);
  const b = ansiToHtml('amarillo en la SIGUIENTE lectura', a.state);
  assert('el color se arrastra al trozo siguiente', b.html.indexOf('color:var(--warning)') !== -1, b.html);
}

console.log('\n-- 256 colores y 24 bits no rompen el flujo --');
{
  const r = ansiToHtml(`${ESC}[38;5;196mrojo256${ESC}[0m`, nuevo());
  assert('38;5;N no deja basura en pantalla', r.html.indexOf('5;196') === -1, r.html);
  assert('y colorea algo', r.html.indexOf('<span style="color:') !== -1, r.html);
}
{
  const r = ansiToHtml(`${ESC}[38;2;10;20;30mrgb${ESC}[0m`, nuevo());
  assert('38;2;R;G;B da el color exacto', r.html.indexOf('rgb(10, 20, 30)') !== -1, r.html);
}

console.log('\n-- secuencias que hay que TRAGARSE, no imprimir --');
{
  // cmd.exe manda un OSC de titulo nada mas arrancar. Sin tragarselo, la
  // primera linea que ve el usuario es basura de escape.
  const r = ansiToHtml(`${ESC}]0;C:\\WINDOWS\\system32\\cmd.exe\x07Microsoft Windows`, nuevo());
  assert('el OSC de titulo desaparece', r.html === 'Microsoft Windows', JSON.stringify(r.html));
}
{
  const r = ansiToHtml(`${ESC}[2J${ESC}[Hlimpio`, nuevo());
  assert('los movimientos de cursor no se imprimen', r.html === 'limpio', JSON.stringify(r.html));
}
{
  const r = ansiToHtml(`${ESC}(B${ESC}=texto`, nuevo());
  assert('los escapes simples tampoco', r.html === 'texto', JSON.stringify(r.html));
}

console.log('\n-- entradas rotas: no debe reventar ni colar el escape --');
{
  const r = ansiToHtml(`${ESC}[`, nuevo());
  assert('una secuencia cortada a la mitad no rompe', typeof r.html === 'string');
  const r2 = ansiToHtml('', nuevo());
  assert('cadena vacia devuelve vacio', r2.html === '');
  const r3 = ansiToHtml(`${ESC}[999mraro`, nuevo());
  assert('un codigo SGR desconocido se ignora y el texto sale', r3.html.indexOf('raro') !== -1, r3.html);
}

if (failed > 0) {
  console.error(`\n${failed} comprobacion(es) FALLAN`);
  process.exit(1);
}
console.log('\nTODAS PASAN');
