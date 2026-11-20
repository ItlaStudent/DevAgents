// S8: prueba del agrupado y la busqueda de la lista de sesiones.
// node tests/sessions_ui_test.cjs
const {
  grupoPorFecha,
  coincideBusqueda,
  planPendienteVigente,
  ordenarPorReciente,
  visibleEnBarra,
  esArchivable,
} = require('../shell/webui/dist/session_groups.test.cjs');

let failed = 0;
function assert(name, cond, detail) {
  if (cond) {
    console.log(`  ok: ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${name} ${detail ? '-> ' + detail : ''}`);
  }
}

// Referencia fija: 12 de agosto de 2026, 10:00 hora local.
const ahora = new Date(2026, 7, 12, 10, 0, 0);
const seg = (d) => Math.floor(d.getTime() / 1000);

console.log('\n-- agrupado por fecha --');
assert(
  'una de esta manana es de Hoy',
  grupoPorFecha(seg(new Date(2026, 7, 12, 9, 30)), ahora) === 'Hoy'
);
assert(
  'una de anoche tarde es de Ayer',
  grupoPorFecha(seg(new Date(2026, 7, 11, 23, 55)), ahora) === 'Ayer'
);
assert(
  'una de hace tres dias es de Esta semana',
  grupoPorFecha(seg(new Date(2026, 7, 9, 12, 0)), ahora) === 'Esta semana'
);
assert(
  'una de hace un mes es de Anteriores',
  grupoPorFecha(seg(new Date(2026, 6, 12, 12, 0)), ahora) === 'Anteriores'
);
assert('sin fecha no inventa un monton', grupoPorFecha(0, ahora) === 'Sin fecha');
assert('una fecha negativa tampoco', grupoPorFecha(-5, ahora) === 'Sin fecha');
assert(
  'una fecha futura cae en Hoy, no en Anteriores',
  grupoPorFecha(seg(new Date(2026, 7, 20, 12, 0)), ahora) === 'Hoy'
);

// LA trampa: el motor guarda SEGUNDOS y Date trabaja en milisegundos. Si se
// pierde el x1000, una sesion de hoy pasa a valer ~1976 y las 215 caen juntas
// en «Anteriores»: la pantalla no se ve rota, solo deja de servir. Se modela
// dividiendo entre 1000 lo que entra, que es exactamente lo que veria la
// funcion sin su conversion.
assert(
  'sin la conversion a milisegundos, una sesion de hoy caeria en Anteriores',
  grupoPorFecha(seg(ahora) / 1000, ahora) === 'Anteriores',
  grupoPorFecha(seg(ahora) / 1000, ahora)
);
assert(
  'con la conversion, esa misma sesion es de Hoy',
  grupoPorFecha(seg(ahora), ahora) === 'Hoy'
);

console.log('\n-- busqueda --');
assert('filtro vacio no filtra', coincideBusqueda('Crea una calculadora', 12, ''));
assert('solo espacios tampoco filtra', coincideBusqueda('Crea una calculadora', 12, '   '));
assert('coincide por titulo, sin importar mayusculas', coincideBusqueda('Crea una Calculadora', 12, 'CALCU'));
assert('coincide por numero de orden', coincideBusqueda('Crea una calculadora', 214, '214'));
assert('no coincide lo que no esta', !coincideBusqueda('Crea una calculadora', 12, 'serpiente'));

console.log('\n-- orden por reciente (22-09) --');
const desordenadas = [
  { id: 752, created_at: 100 },
  { id: 700, created_at: 50 },
  { id: 755, created_at: 300 },
  { id: 754, created_at: 300 },
];
const ordenadas = ordenarPorReciente(desordenadas).map((s) => s.id);
assert('la mas reciente primero, empate por id', JSON.stringify(ordenadas) === '[755,754,752,700]', JSON.stringify(ordenadas));
assert('no muta la lista original', desordenadas[0].id === 752);

console.log('\n-- planes pendientes vigentes (22-09) --');assert('un plan de hace una hora espera aprobacion', planPendienteVigente('planned', seg(ahora) - 3600, ahora));
assert('un plan de hace dos dias ya no', !planPendienteVigente('planned', seg(ahora) - 2 * 86400, ahora));
assert('justo en el limite de 24 h ya no', !planPendienteVigente('planned', seg(ahora) - 86400, ahora));
assert('una orden hecha nunca es pendiente', !planPendienteVigente('done', seg(ahora) - 60, ahora));
assert('sin fecha no se promociona a pendiente', !planPendienteVigente('planned', 0, ahora));

console.log('\n-- CK-CAB-003 archivo: interruptor Ver archivadas --');
// Sin el interruptor, el historial solo enseña lo NO archivado; con él, solo lo
// archivado. Si esta regla se invierte, la fila archivada se cuela en el día a
// día (o la activa desaparece), y la pantalla no se ve rota — solo pierde
// sesiones.
assert('CK-CAB-003 archivo helpers exportados', typeof visibleEnBarra === 'function' && typeof esArchivable === 'function');
if (typeof visibleEnBarra === 'function' && typeof esArchivable === 'function') {
assert('activa visible sin interruptor', visibleEnBarra({ archived_at: 0 }, false));
assert('activa oculta con interruptor', !visibleEnBarra({ archived_at: 0 }, true));
assert('archivada oculta sin interruptor', !visibleEnBarra({ archived_at: 1710000000 }, false));
assert('archivada visible con interruptor', visibleEnBarra({ archived_at: 1710000000 }, true));
assert('sin campo archived_at equivale a activa', visibleEnBarra({}, false) && !visibleEnBarra({}, true));
assert('archived_at null equivale a activa', visibleEnBarra({ archived_at: null }, false));

console.log('\n-- CK-CAB-003 archivo: solo se archiva lo terminal --');
assert('done es archivabla', esArchivable('done'));
assert('failed es archivabla', esArchivable('failed'));
assert('rejected es archivabla', esArchivable('rejected'));
assert('cancelled es archivabla', esArchivable('cancelled'));
assert('audit_unavailable es archivabla', esArchivable('audit_unavailable'));
assert('una en curso NO se archiva', !esArchivable('running'));
assert('un plan aprobado NO se archiva', !esArchivable('approved'));
assert('una que espera aprobacion NO se archiva', !esArchivable('awaiting_approval'));
assert('sin estado no se archiva', !esArchivable(undefined));

}
console.log(`\n${failed === 0 ? 'TODAS LAS PRUEBAS DE SESIONES PASARON' : failed + ' FALLOS'}`);
process.exit(failed === 0 ? 0 : 1);
