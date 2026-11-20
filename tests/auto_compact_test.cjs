// D6: prueba del umbral, la cuenta atras y el «posponer» de la compactacion
// automatica. node tests/auto_compact_test.cjs
const a = require('../shell/webui/dist/auto_compact.test.cjs');

let failed = 0;
function assert(name, cond, detail) {
  if (cond) {
    console.log(`  ok: ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${name} ${detail ? '-> ' + detail : ''}`);
  }
}

// 32768 tokens de ventana, ~4 caracteres por token: el 75 % son 98.304
// caracteres. Se prueban los dos lados del borde, no un numero comodo.
const LIMITE_CHARS = 32768 * 4;
const bajoUmbral = Math.floor(LIMITE_CHARS * 0.7);
const sobreUmbral = Math.floor(LIMITE_CHARS * 0.8);
const justoDebajo = Math.floor(LIMITE_CHARS * 0.74);

console.log('\n-- porcentaje --');
assert('70 % del limite da 70', a.porcentajeContexto(bajoUmbral) === 70, String(a.porcentajeContexto(bajoUmbral)));
assert('80 % del limite da 80', a.porcentajeContexto(sobreUmbral) === 80, String(a.porcentajeContexto(sobreUmbral)));
assert('nunca pasa de 100', a.porcentajeContexto(LIMITE_CHARS * 10) === 100);
assert('limite 0 no divide entre cero', a.porcentajeContexto(1000, 0) === 0);

console.log('\n-- el umbral --');
assert(
  'por debajo del 75 % no hace nada',
  a.decidir(bajoUmbral, 4, a.estadoInicial()).accion === 'nada'
);
assert(
  'justo por debajo del 75 % tampoco',
  a.decidir(justoDebajo, 4, a.estadoInicial()).accion === 'nada',
  a.decidir(justoDebajo, 4, a.estadoInicial()).accion
);
assert(
  'por encima del 75 % arranca la cuenta atras',
  a.decidir(sobreUmbral, 4, a.estadoInicial()).accion === 'arrancar'
);
assert(
  'con un solo turno no hay nada que resumir',
  a.decidir(sobreUmbral, 1, a.estadoInicial()).accion === 'nada'
);

console.log('\n-- se compacta SOLA (el disparo que faltaba) --');
{
  let estado = a.estadoInicial();
  let d = a.decidir(sobreUmbral, 4, estado);
  assert('primer paso: arrancar', d.accion === 'arrancar' && d.restanS === a.CUENTA_ATRAS_S);
  estado = a.arrancar(estado, d.restanS);

  // Sin intervencion: solo pasa el tiempo.
  for (let i = 0; i < a.CUENTA_ATRAS_S; i++) {
    const paso = a.decidir(sobreUmbral, 4, estado);
    if (i < a.CUENTA_ATRAS_S) {
      // Mientras queden segundos, sigue contando.
      if (estado.restanS > 0) {
        assert(`tic ${i}: sigue contando`, paso.accion === 'contando', paso.accion);
      }
    }
    estado = a.tic(estado);
  }
  const fin = a.decidir(sobreUmbral, 4, estado);
  assert('agotado el plazo: COMPACTAR sin que nadie toque nada', fin.accion === 'compactar', fin.accion);
}

console.log('\n-- «Posponer» manda en ese hilo --');
{
  let estado = a.arrancar(a.estadoInicial());
  estado = a.posponer(estado);
  for (let i = 0; i < a.CUENTA_ATRAS_S + 5; i++) estado = a.tic(estado);
  assert(
    'tras posponer no se compacta por mucho que pase el tiempo',
    a.decidir(sobreUmbral, 4, estado).accion === 'nada'
  );
  assert('y el reloj queda parado', estado.restanS === null);
  // Pero «Compactar ahora» lo rearma.
  const forzado = a.forzada(estado);
  assert('«Compactar ahora» rearma el posponer', forzado.pospuesto === false && forzado.enMarcha === true);
}

console.log('\n-- un resumen fallido no se reintenta solo --');
{
  let estado = a.enMarcha(a.arrancar(a.estadoInicial()));
  estado = a.terminada(estado, false);
  assert('queda marcado el fallo', estado.falloPrevio === true);
  assert('y no vuelve a dispararse solo', a.decidir(sobreUmbral, 4, estado).accion === 'nada');
  const rearmado = a.forzada(estado);
  assert('hasta que el usuario lo pide', rearmado.falloPrevio === false);
}

console.log('\n-- una compactacion buena deja el hilo limpio --');
{
  const estado = a.terminada(a.enMarcha(a.estadoInicial()), true);
  assert('estado inicial de nuevo', estado.pospuesto === false && estado.enMarcha === false && estado.restanS === null && estado.falloPrevio === false);
}

console.log('\n-- no se lanzan dos compactaciones a la vez --');
{
  const estado = a.enMarcha(a.estadoInicial());
  assert('con una en vuelo, no arranca otra', a.decidir(sobreUmbral, 4, estado).accion === 'nada');
}

if (failed > 0) {
  console.error(`\n${failed} comprobacion(es) FALLAN`);
  process.exit(1);
}
console.log('\nTODAS PASAN');
