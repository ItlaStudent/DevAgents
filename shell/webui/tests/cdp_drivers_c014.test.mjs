// Pruebas puras (sondeo de estabilización y conteo de colores del editor) contra
// tools/cdp_relevo_scenarios.mjs. DOM sintético con objetos simples: jsdom no está en node_modules.
// Un solo comando por driver (verde, exit 0):
//   node --test shell/webui/tests/cdp_drivers_c014.test.mjs
// Modo roja: la conducta antigua del driver (una sola medición, sin puerta de puerto/cabina y
// sin distinguir el render monocromo) debe seguir RECHAZADA; sale con exit 1:
//   node shell/webui/tests/cdp_drivers_c014.test.mjs --roja
import assert from 'node:assert/strict';
import test from 'node:test';
import vm from 'node:vm';
import {
  firmaRender, estableEnDosLecturas, contarColores, coloresDeLectura, sintetizarSondeo,
  filaEditor, veredictoFila, motivosDeFila, resumenEditor, tablaEditorTexto,
  sondearEditor, expresionSondeoEditor,
  validarPuertoPrueba, esCabinaDevAgents,
} from '../../../tools/cdp_relevo_scenarios.mjs';

const roja = process.argv.includes('--roja');

// Lecturas sintéticas del DOM renderizado.
const lecturaA = { hostVisible: true, lineasVisibles: 3, spansVisibles: 10, colores: ['rgb(1, 2, 3)', 'rgb(4, 5, 6)'] };
const lecturaA2 = structuredClone(lecturaA);
const lecturaB = { ...lecturaA, colores: ['rgb(1, 2, 3)'] };
const lecturaC = { ...lecturaA, spansVisibles: 11 };

const inmediato = fn => fn();
function relojFalso(inicio = 0, paso = 10) {
  let t = inicio;
  return () => { const actual = t; t += paso; return actual; };
}
function secuencia(lecturas) {
  let i = 0;
  return () => {
    if (i >= lecturas.length) throw new Error('Secuencia agotada');
    return structuredClone(lecturas[i++]);
  };
}

const fila = () => filaEditor({
  extension: 'html', tema: 'light', escala: '150', languageId: 'html',
  estado: 'html', tiposToken: ['cm-tags', 'mtk1'],
  sondeo: sintetizarSondeo([lecturaB, lecturaA, lecturaA2]),
});

if (roja) {
  test('roja CK-CAB-014: la lógica antigua no distinguía el render monocromo', () => {
    const una = { hostVisible: true, lineasVisibles: 2, spansVisibles: 4, colores: ['rgb(9, 9, 9)'] };
    const filaAntigua = filaEditor({
      extension: 'html', tema: 'black', escala: '100', languageId: 'html',
      estado: 'html', tiposToken: ['mtk1'],
      sondeo: { ultima: una, previa: null, vueltas: 1, estable: true },
    });
    assert.equal(filaAntigua.monocromo, false,
      'La lógica antigua no distinguía la presentación monocroma del DOM renderizado');
  });

  test('roja CK-CAB-014: la lógica antigua daba por estable una sola medición', () => {
    assert.equal(sintetizarSondeo([lecturaA]).estable, true,
      'La lógica antigua no exigía dos lecturas seguidas');
  });

  test('roja CK-CAB-014: romper la firma del sondeo real pone la prueba en rojo', async () => {
    const mutado = await sondearEditor({
      leer: secuencia([lecturaA, lecturaB, lecturaB]),
      firma: () => 'firma-constante',
      ahora: relojFalso(), programar: inmediato, plazoMs: 1000,
    });
    assert.equal(mutado.estable, false,
      'Con la firma rota, el sondeo real no debe declarar estable lecturas distintas');
  });

  test('roja CK-CAB-014: la lógica antigua aceptaba cualquier puerto y página', () => {
    assert.equal(validarPuertoPrueba('9334'), 9334,
      'La conducta antigua aceptaba cualquier puerto sin --permitir-puerto');
    assert.equal(esCabinaDevAgents({ titulo: 'Otra aplicación', marca: false }), true,
      'La conducta antigua no comprobaba que la página fuese la cabina de DevAgents');
  });
} else {
  test('r4: sondearEditor vence aunque nunca lleguen frames', async () => {
    const plazoMs = 60;
    let vigilancia;
    let callback;
    const cancelados = [];
    let lecturas = 0;
    const inicio = performance.now();
    try {
      const salida = await Promise.race([
        sondearEditor({
          leer: () => { lecturas++; return lecturaA; }, plazoMs,
          programar: fn => { callback = fn; return 42; },
          cancelar: id => cancelados.push(id),
        }),
        new Promise((_, reject) => {
          vigilancia = setTimeout(() => reject(new Error('El sondeo no termina sin frames')), 600);
        }),
      ]);
      const transcurrido = performance.now() - inicio;
      assert(transcurrido >= plazoMs - 5 && transcurrido < 600, `Plazo ${plazoMs} ms; transcurrido ${transcurrido} ms`);
      assert.equal(salida.estable, false);
      assert.equal(salida.vencido, true);
      assert.deepEqual(salida.lecturas, []);
      assert.deepEqual(cancelados, [42]);
      callback(); // Un callback ya encolado tampoco debe leer después del cierre.
      assert.equal(lecturas, 0);
      console.log(`r4 sin frames: plazo=${plazoMs} ms, transcurrido=${transcurrido.toFixed(1)} ms`);
    } finally {
      clearTimeout(vigilancia);
    }
  });

  test('r4: expresión CDP vence y cancela el frame sin entregar callbacks', async () => {
    const cancelados = [];
    const contexto = {
      setTimeout, clearTimeout,
      requestAnimationFrame: () => 7,
      cancelAnimationFrame: id => cancelados.push(id),
    };
    const salida = await vm.runInNewContext(expresionSondeoEditor(30), contexto);
    assert.equal(salida.estable, false);
    assert.equal(salida.vencido, true);
    assert.equal(salida.lecturas.length, 0);
    assert.deepEqual(cancelados, [7]);
  });

  test('firmaRender es estable ante lecturas iguales y sensible a cambios', () => {
    assert.equal(firmaRender(lecturaA), firmaRender(lecturaA2));
    assert.notEqual(firmaRender(lecturaA), firmaRender(lecturaB));
    assert.notEqual(firmaRender(lecturaA), firmaRender(lecturaC));
    assert.throws(() => firmaRender(null), TypeError);
  });

  test('estableEnDosLecturas exige dos lecturas seguidas', () => {
    assert.equal(estableEnDosLecturas(lecturaA, lecturaA2), true);
    assert.equal(estableEnDosLecturas(lecturaA, lecturaB), false);
    assert.equal(estableEnDosLecturas(null, lecturaA), false);
  });

  test('coloresDeLectura/contarColores deduplican, ordenan e ignoran nulos', () => {
    assert.deepEqual(coloresDeLectura(lecturaA), ['rgb(1, 2, 3)', 'rgb(4, 5, 6)']);
    assert.equal(contarColores(lecturaA), 2);
    assert.equal(contarColores({ colores: ['rgb(1,2,3)', 'rgb(1,2,3)', null] }), 1);
    assert.equal(contarColores({ colores: [] }), 0);
    assert.throws(() => contarColores({}), TypeError);
  });

  test('sondearEditor (lógica real) estabiliza con dos lecturas iguales seguidas', async () => {
    const salida = await sondearEditor({
      leer: secuencia([lecturaA, lecturaA2]),
      ahora: relojFalso(), programar: inmediato, plazoMs: 1000,
    });
    assert.equal(salida.vencido, false);
    assert.equal(salida.lecturas.length, 2);
    assert.equal(estableEnDosLecturas(salida.lecturas[0], salida.lecturas[1]), true);
  });

  test('sondearEditor (lógica real) no estabiliza lecturas distintas y vence el plazo', async () => {
    const salida = await sondearEditor({
      leer: secuencia([lecturaA, lecturaB, lecturaC]),
      ahora: relojFalso(0, 10), programar: inmediato, plazoMs: 25,
    });
    assert.equal(salida.vencido, true);
    assert.equal(salida.lecturas.length, 3);
    assert.deepEqual(salida.lecturas[2], lecturaC);
  });

  test('sondearEditor (lógica real) conserva una sola lectura si el plazo ya venció', async () => {
    const salida = await sondearEditor({
      leer: secuencia([lecturaA]), ahora: relojFalso(), programar: inmediato, plazoMs: 0,
    });
    assert.equal(salida.vencido, true);
    assert.equal(salida.lecturas.length, 1);
  });

  test('sondearEditor (lógica real) captura el error del lector', async () => {
    const salida = await sondearEditor({
      leer: () => { throw new Error('DOM ausente'); },
      ahora: relojFalso(), programar: inmediato, plazoMs: 1000,
    });
    assert.equal(salida.lecturas.length, 0);
    assert.match(salida.error, /DOM ausente/);
  });

  test('romper la firma inyectada demuestra que la prueba de estabilización es sensible', async () => {
    const mutado = await sondearEditor({
      leer: secuencia([lecturaA, lecturaB, lecturaB]),
      firma: () => 'firma-constante',
      ahora: relojFalso(), programar: inmediato, plazoMs: 1000,
    });
    assert.equal(mutado.estable, true);
    assert.equal(estableEnDosLecturas(lecturaA, lecturaB), false);
  });

  test('expresionSondeoEditor inyecta la lógica real y mide el DOM sintético', async () => {
    const expresion = expresionSondeoEditor(1000);
    assert.match(expresion, /function firmaRender/);
    assert.match(expresion, /function estableEnDosLecturas/);
    assert.match(expresion, /function sondearEditor/);
    const span = color => ({ getClientRects: () => [1], color });
    const linea = { getClientRects: () => [1] };
    const contexto = {
      document: {
        querySelector: sel => (sel === '#editor-monaco-host' ? { getClientRects: () => [1] } : null),
        querySelectorAll: sel => {
          if (sel.includes('span[class*=mtk]')) return [span('rgb(1, 2, 3)'), span('rgb(4, 5, 6)')];
          if (sel.includes('.view-line')) return [linea, linea];
          return [];
        },
      },
      getComputedStyle: el => ({ color: el.color }),
      requestAnimationFrame: fn => fn(),
      setTimeout, clearTimeout,
    };
    const salida = await vm.runInNewContext(expresion, contexto);
    assert.equal(salida.vencido, false);
    assert.equal(salida.lecturas.length, 2);
    assert.equal(salida.lecturas[1].hostVisible, true);
    assert.equal(salida.lecturas[1].lineasVisibles, 2);
    assert.equal(salida.lecturas[1].spansVisibles, 2);
    assert.deepEqual(Array.from(salida.lecturas[1].colores).sort(), ['rgb(1, 2, 3)', 'rgb(4, 5, 6)']);
  });

  test('sintetizarSondeo toma las dos últimas lecturas, no estabiliza con una y conserva el plazo', () => {
    const sondeo = sintetizarSondeo([lecturaA, lecturaB, lecturaB]);
    assert.equal(sondeo.vueltas, 3);
    assert.equal(sondeo.estable, true);
    assert.deepEqual(sondeo.ultima, lecturaB);
    assert.equal(sondeo.previa, lecturaB);
    const sondeoCorto = sintetizarSondeo([lecturaA]);
    assert.equal(sondeoCorto.estable, false);
    assert.equal(sondeoCorto.previa, null);
    assert.equal(sondeoCorto.vencido, false);
    assert.equal(sintetizarSondeo([lecturaA], true).vencido, true);
    assert.throws(() => sintetizarSondeo([]), TypeError);
  });

  test('filaEditor recoge la medición del render y el caso de plazo vencido', () => {
    const completa = fila();
    assert.equal(completa.extension, 'html');
    assert.equal(completa.languageId, 'html');
    assert.equal(completa.hostVisible, true);
    assert.equal(completa.lineasVisibles, 3);
    assert.equal(completa.spansVisibles, 10);
    assert.deepEqual(completa.colores, ['rgb(1, 2, 3)', 'rgb(4, 5, 6)']);
    assert.equal(completa.estable, true);
    assert.equal(completa.monocromo, false);
    assert.equal(completa.vencido, false);
    assert.equal(completa.vueltas, 3);
    // Plazo vencido con una lectura renderizada de UN color: monocromo y vencida.
    const lecturaMonocroma = { ...lecturaA, colores: ['rgb(1, 2, 3)'] };
    const vencida = filaEditor({
      extension: 'py', tema: 'black', escala: '100', languageId: 'python',
      estado: 'python', tiposToken: ['mtk1'],
      sondeo: sintetizarSondeo([lecturaMonocroma], true),
    });
    assert.equal(vencida.estable, false);
    assert.equal(vencida.vencido, true);
    assert.equal(vencida.monocromo, true);
    assert.equal(vencida.colores.length, 1);
    assert.equal(vencida.hostVisible, true);
    // Plazo vencido con dos colores NO es monocromo: monocromo mide el render, no el plazo.
    const vencidaBicolor = filaEditor({
      extension: 'html', tema: 'light', escala: '150', languageId: 'html',
      estado: 'html', tiposToken: ['mtk1'],
      sondeo: sintetizarSondeo([lecturaA], true),
    });
    assert.equal(vencidaBicolor.vencido, true);
    assert.equal(vencidaBicolor.monocromo, false);
    assert.equal(vencidaBicolor.colores.length, 2);
    assert.throws(() => filaEditor({ extension: 'x', tema: 'black', escala: '100', languageId: 'x', sondeo: null }), TypeError);
  });

  test('veredictoFila exige >1 color con la misma medición del resumen', () => {
    assert.equal(veredictoFila(fila()), 'OK');
    assert.equal(veredictoFila({ ...fila(), colores: ['rgb(1, 2, 3)'] }), 'FALLA');
    assert.equal(veredictoFila({ ...fila(), estable: false }), 'FALLA');
    assert.equal(veredictoFila({ ...fila(), hostVisible: false }), 'FALLA');
    assert.equal(veredictoFila({ ...fila(), lineasVisibles: 0 }), 'FALLA');
    assert.equal(veredictoFila({ ...fila(), spansVisibles: 0 }), 'FALLA');
    assert.throws(() => veredictoFila(null), TypeError);
  });

  test('motivosDeFila enumera el diagnóstico completo de una fila rota', () => {
    const rota = { ...fila(), hostVisible: false, lineasVisibles: 0, colores: ['rgb(1,2,3)'], estable: false, estado: 'TEXT' };
    assert.deepEqual(motivosDeFila(rota),
      ['host invisible', 'sin líneas visibles', 'colores=1 (se exige >1)', 'firma inestable al vencer el plazo', 'estado']);
    assert.deepEqual(motivosDeFila(fila()), []);
    assert.throws(() => motivosDeFila(null), TypeError);
  });

  test('resumenEditor y tablaEditorTexto agregan y formatean la matriz', () => {
    const resumen = resumenEditor([
      { tema: 'black', escala: '100', extension: 'html', veredicto: 'OK' },
      { tema: 'black', escala: '100', extension: 'py', veredicto: 'FALLA' },
      { tema: 'light', escala: '150', extension: 'md', veredicto: 'OK' },
    ]);
    assert.equal(resumen.total, 3);
    assert.equal(resumen.ok, 2);
    assert.equal(resumen.fallos, 1);
    assert.deepEqual(resumen.bloques['black-100'].fallos, ['py']);
    assert.equal(resumen.bloques['light-150'].ok, 1);
    assert.throws(() => resumenEditor('no-lista'), TypeError);
    const tabla = tablaEditorTexto([{
      tema: 'black', escala: '100', extension: 'html', veredicto: 'OK', hostVisible: true,
      lineasVisibles: 1, spansVisibles: 3, colores: ['c1', 'c2'], tiposToken: ['mtk1'], estable: true, vencido: false, motivos: [],
    }]);
    const lineas = tabla.trimEnd().split('\n');
    assert.equal(lineas.length, 2);
    assert.match(lineas[0], /^tema;escala;ext;veredicto/);
    assert.match(lineas[1], /black;100;html;OK;true;1;3;c1\|c2;mtk1;true;false;/);
    assert.throws(() => tablaEditorTexto(null), TypeError);
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
}
