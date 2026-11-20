// Pruebas puras (secuencia de flechas del selector de modelos) contra
// tools/cdp_ux_cabina.mjs. DOM sintético con objetos simples: jsdom no está en node_modules.
// Un solo comando por driver (verde, exit 0):
//   node --test shell/webui/tests/cdp_drivers_c013.test.mjs
// Modo roja: la conducta antigua del driver (sin filtro de grupo abierto y envolviendo en los
// extremos) debe seguir RECHAZADA; sale con exit 1:
//   node shell/webui/tests/cdp_drivers_c013.test.mjs --roja
import assert from 'node:assert/strict';
import test from 'node:test';
import {
  elementosDeFlechas, sinEnvolver, validarPuertoPrueba, esCabinaDevAgents,
} from '../../../tools/cdp_ux_cabina.mjs';

const roja = process.argv.includes('--roja');

// Registro DOM en orden: encabezados y opciones de grupos (abierto o colapsado).
const todoAbierto = [
  { kind: 'encabezado', grupoAbierto: true, grupo: 'provider:demo', texto: 'Proveedores' },
  { kind: 'opcion', grupoAbierto: true, grupo: 'provider:demo', dataVal: 'demo:a', texto: 'a' },
];

const mixto = [
  { kind: 'encabezado', grupoAbierto: true, grupo: 'g1', texto: 'g1' },
  { kind: 'opcion', grupoAbierto: true, grupo: 'g1', dataVal: 'g1:o1', texto: 'o1' },
  { kind: 'encabezado', grupoAbierto: false, grupo: 'g2', texto: 'g2' },
  { kind: 'opcion', grupoAbierto: false, grupo: 'g2', dataVal: 'g2:o1', texto: 'oculta por colapso' },
  { kind: 'opcion', grupoAbierto: true, grupo: 'g1', dataVal: 'g1:o2', texto: 'o2 caída', caido: true },
];

// Conducta antigua: el driver no filtraba por grupo abierto y no definía los extremos.
const conductaAntigua = [
  { kind: 'encabezado', grupoAbierto: true, texto: 'g1' },
  { kind: 'opcion', grupoAbierto: true, texto: 'o1' },
  { kind: 'encabezado', grupoAbierto: false, texto: 'g2' },
  { kind: 'opcion', grupoAbierto: false, texto: 'o2' },
];

if (roja) {
  test('roja CK-CAB-013: la lógica antigua no filtraba grupos colapsados', () => {
    assert.equal(elementosDeFlechas(conductaAntigua).length, conductaAntigua.length,
      'La lógica antigua (sin filtro de grupo) no distinguía grupos colapsados');
  });

  test('roja CK-CAB-013: la lógica antigua envolvía en el extremo', () => {
    assert.equal(sinEnvolver(4, 3, true), 0,
      'La conducta antigua envolvía al final en lugar de quedarse en el último');
  });

  test('roja CK-CAB-013: la lógica antigua aceptaba cualquier puerto', () => {
    assert.equal(validarPuertoPrueba('9334'), 9334,
      'La conducta antigua aceptaba cualquier puerto sin --permitir-puerto');
  });

  test('roja CK-CAB-013: la lógica antigua no verificaba la cabina', () => {
    assert.equal(esCabinaDevAgents({ titulo: 'Otra aplicación', marca: false }), true,
      'La conducta antigua no comprobaba que la página fuese la cabina de DevAgents');
  });
} else {
  test('todo abierto conserva el orden DOM', () => {
    assert.deepEqual(elementosDeFlechas(todoAbierto).map(e => e.texto), ['Proveedores', 'a']);
  });

  test('grupo colapsado y opción «caída»', () => {
    assert.deepEqual(elementosDeFlechas(mixto).map(e => e.texto), ['g1', 'o1', 'g2', 'o2 caída']);
  });

  test('sin envolver en los extremos', () => {
    assert.equal(sinEnvolver(3, 2, true), 2);
    assert.equal(sinEnvolver(3, 0, false), 0);
    assert.equal(sinEnvolver(3, 1, true), 2);
    assert.equal(sinEnvolver(3, 1, false), 0);
  });

  test('entradas inválidas rechazadas (formato y rango)', () => {
    assert.throws(() => elementosDeFlechas(null), TypeError);
    assert.throws(() => elementosDeFlechas('no-lista'), TypeError);
    assert.throws(() => sinEnvolver(0, 0, true), TypeError);
    assert.throws(() => sinEnvolver(3, -1, true), RangeError);
    assert.throws(() => sinEnvolver(3, 3, true), RangeError);
  });

  test('secuencia vacía sin elementos', () => {
    assert.deepEqual(elementosDeFlechas([]), []);
  });

  test('sólo la cabina de prueba 9333, salvo --permitir-puerto explícito', () => {
    assert.equal(validarPuertoPrueba('9333'), 9333);
    assert.equal(validarPuertoPrueba(9333), 9333);
    assert.throws(() => validarPuertoPrueba('9334'), /permitir-puerto/);
    assert.equal(validarPuertoPrueba('9334', true), 9334);
    assert.throws(() => validarPuertoPrueba('abc'), /Puerto CDP inválido/);
    assert.throws(() => validarPuertoPrueba('0'), /Puerto CDP inválido/);
    assert.throws(() => validarPuertoPrueba('65536'), /Puerto CDP inválido/);
  });

  test('la página debe identificarse como cabina de DevAgents', () => {
    assert.equal(esCabinaDevAgents({ titulo: 'Sala — DevAgents', marca: false }), true);
    assert.equal(esCabinaDevAgents({ titulo: '', marca: true }), true);
    assert.equal(esCabinaDevAgents({ titulo: 'Otra aplicación', marca: false }), false);
    assert.equal(esCabinaDevAgents(null), false);
  });

  test('la conducta antigua (sin filtro de grupo abierto / envolver) queda rechazada', () => {
    assert.throws(() => assert.equal(elementosDeFlechas(conductaAntigua).length, conductaAntigua.length,
      'sin filtro de grupo'), assert.AssertionError);
    assert.throws(() => assert.equal(sinEnvolver(4, 3, true), 0, 'envolver al final'), assert.AssertionError);
  });
}
