// Prueba de la lógica REAL de ui_diag sobre los escenarios medidos.
// node tests/diag_ui_test.cjs
const {
  describeProviderFailure,
  synthProblems,
  classifyActions,
  terminalOrderPhase,
  workspaceRestoreDiagnostic,
} = require('../shell/webui/dist/ui_diag.test.cjs');

let failed = 0;
function assert(name, cond, detail) {
  if (cond) {
    console.log(`  ok: ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${name} ${detail ? '-> ' + detail : ''}`);
  }
}

const aclDiagnostic = 'snapshot: fallo; etapa=raiz; ruta=.; error=CliWritableByOthers; win32=0; escritores=grupo CodexSandboxUsers; SID sintetico sin cuenta; otro escritor; accion=workspace_acl_restore (Restaurar permisos del espacio)';
const aclEvent = text => ({kind:'external_agent_finished',payload:{error:text}});
assert('B2: raíz rechazada ofrece restauración con todos los escritores visibles', workspaceRestoreDiagnostic([aclEvent(aclDiagnostic)]) === aclDiagnostic);
assert('B2: perfil o binario rechazado no ofrece restaurar el espacio', workspaceRestoreDiagnostic([aclEvent('CliWritableByOthers')]) === null);
assert('B2: archivo anidado no ofrece restaurar raíz', workspaceRestoreDiagnostic([aclEvent(aclDiagnostic.replace('etapa=raiz; ruta=.', 'etapa=apertura; ruta=user.txt'))]) === null);
assert('B2: rechazo sin acción nativa no ofrece restaurar', workspaceRestoreDiagnostic([aclEvent(aclDiagnostic.replace('accion=workspace_acl_restore', 'accion=otra'))]) === null);
assert('B2: último intento exitoso retira oferta antigua', workspaceRestoreDiagnostic([aclEvent(aclDiagnostic),{kind:'external_agent_finished',payload:{success:true}}]) === null);
assert('B2: vacío no ofrece acción', workspaceRestoreDiagnostic([]) === null);

// ── P3: qué le dice la interfaz al usuario sobre un fallo ────────────────

// Escenario orden 148: respondió 6788 caracteres, closed=true.
const caso148 = describeProviderFailure({
  status: 'empty', model: 'north-mini-code-1-0', provider: 'Cohere',
  total_len: 6788, closed: true, sample: '{"field":"source","content":"import tkinter...',
});
console.log('\n148:', caso148);
assert('148 dice 6,788 caracteres', caso148.includes('6,788 caracteres'), caso148);
assert('148 dice que cerró su contenedor JSON', caso148.includes('cerró su contenedor JSON'), caso148);
assert('148 NO dice "no sirvió"', !caso148.includes('no sirvió'), caso148);

const casoMuerto = describeProviderFailure({ status: 'empty', provider: 'OpenCode', model: 'x' });
console.log('\nmuerto:', casoMuerto);
assert('muerto dice "no devolvió texto"', casoMuerto.includes('no devolvió texto'), casoMuerto);
assert('muerto marca fallo real del proveedor', casoMuerto.includes('fallo real del proveedor'), casoMuerto);

const casoTruncado = describeProviderFailure({ status: 'empty', total_len: 4000, closed: false });
console.log('\ntruncado:', casoTruncado);
assert('truncado dice que quedó truncada', casoTruncado.includes('truncada'), casoTruncado);

const casoAuth = describeProviderFailure({ status: 'auth_failed', error_name: 'AuthFailed', total_len: 0 });
console.log('\nauth:', casoAuth);
assert('auth muestra el error_name', casoAuth.includes('AuthFailed'), casoAuth);

const problemas = synthProblems([
  { id: 1, ts: 1, source: 'live_worker', kind: 'task_provider_failed', payload: { task_id: 't1' } },
  { id: 2, ts: 2, source: 'live_worker', kind: 'task_provider_failed', payload: { task_id: 't1' } },
  { id: 3, ts: 3, source: 'live_worker', kind: 'task_failed', payload: { task_id: 't2', cause: 'execution_failed' } },
  { id: 4, ts: 4, source: 'live_worker', kind: 'order_failed', payload: { cause: 'all_tasks_failed' } },
]);
console.log('\nproblemas:', problemas);
assert('problemas contiene order_failed con causa', problemas.some((s) => s.includes('all_tasks_failed')), JSON.stringify(problemas));
assert('problemas contiene task_failed con causa', problemas.some((s) => s.includes('execution_failed')), JSON.stringify(problemas));
assert('problemas resume los intentos sin ok', problemas.some((s) => s.includes('2 intento(s) fallido(s)')), JSON.stringify(problemas));

const conExito = synthProblems([
  { id: 1, ts: 1, source: 'live_worker', kind: 'task_provider_failed', payload: {} },
  { id: 2, ts: 2, source: 'live_worker', kind: 'task_provider_ok', payload: {} },
  { id: 3, ts: 3, source: 'live_worker', kind: 'task_failed', payload: { task_id: 't2', cause: 'execution_failed' } },
]);
console.log('\nconExito:', conExito);
assert('conExito conserva el task_failed', conExito.some((s) => s.includes('execution_failed')), JSON.stringify(conExito));
assert('conExito NO dice "Ningún proveedor completó"', !conExito.some((s) => s.includes('Ningún proveedor')), JSON.stringify(conExito));

// ── P4: clasificación por niveles (plegado del chat) ─────────────────────
function ev(kind, payload) {
  return { id: 1, ts: 1, source: 'live_worker', kind, payload };
}
const ordenFallida148 = [
  ev('order_running', { order_id: 148 }),
  ev('superagent_thinking', { text: 'Ola 1 de 2: ejecutando 1 tarea(s) en paralelo…' }),
  ev('superagent_thinking', { text: 'razonamiento interno del modelo, nivel depuración' }),
  ev('task_started', { task_id: 't1', department: 'programacion', task_type: 'programar', description: 'Crear la calculadora' }),
  ev('task_provider_failed', { task_id: 't1', provider: 'Cohere', model: 'north-mini-code-1-0', status: 'empty', total_len: 6788, closed: true }),
  ev('provider_fallback', { to_provider: 'OpenCode', to_model: 'deepseek-v4-flash' }),
  ev('task_provider_ok', { task_id: 't1', provider: 'OpenCode', model: 'deepseek-v4-flash', status: 'ok', key_label: 'KC2' }),
  ev('file_written', { task_id: 't1', file_path: 'orden-148\\calculadora.py' }),
  ev('process_launched', { task_id: 't1', file: 'calculadora.py', pid: 4401 }),
  ev('task_failed', { task_id: 't2', success: false, cause: 'execution_failed', error_msg: 'EOFError: EOF when reading a line' }),
  ev('order_failed', { completed: 0, failed: 1, cause: 'all_tasks_failed' }),
];
const b148 = classifyActions(ordenFallida148);

console.log('\nP4 niveles (orden 148):');
console.log('  fijos  :', b148.fijos.map((f) => f.titulo).join(' | '));
console.log('  olas   :', b148.olas.length, '| tareas:', b148.tareas.length);
console.log('  proveedores:', b148.proveedores.length, 'distintos:', b148.proveedoresDistintos, 'fallidos:', b148.proveedoresFallidos, '| fallbacks:', b148.fallbacks);

// olas excluyen el razonamiento
assert('P4: 1 ola detectada (el razonamiento no se cuenta como ola)', b148.olas.length === 1, String(b148.olas.length));
assert('P4: la ola es la de "Ola 1 de 2"', /^Ola 1 de 2/.test(b148.olas[0] || ''), b148.olas[0]);
// primer error SIEMPRE visible, con causa real
assert('P4: primer error capturado con causa (EOFError)', !!b148.primerError && b148.primerError.detalle.includes('EOFError'), b148.primerError && b148.primerError.detalle);
// archivos y procesos siempre visibles
assert('P4: file_written es fijo visible', b148.fijos.some((f) => f.titulo.includes('calculadora.py')), '');
assert('P4: process_launched es fijo visible', b148.fijos.some((f) => f.titulo.includes('Lanzó calculadora.py')), '');
// proveedores agrupados con resumen
assert('P4: 2 proveedores distintos', b148.proveedoresDistintos === 2, String(b148.proveedoresDistintos));
assert('P4: 1 proveedor fallido', b148.proveedoresFallidos === 1, String(b148.proveedoresFallidos));
assert('P4: fallbacks contados (1)', b148.fallbacks === 1, String(b148.fallbacks));
assert('P4: tareas agrupadas (1 iniciada)', b148.tareas.length === 1, String(b148.tareas.length));

// El razonamiento del modelo NO produce ninguna tarjeta, ni fija ni de grupo.
const soloRazonamiento = classifyActions([ev('superagent_thinking', { text: 'pensando…' })]);
assert('P4: superagent_thinking sin "Ola" no produce tarjetas', soloRazonamiento.fijos.length === 0 && soloRazonamiento.olas.length === 0, '');

// Con cero oks, el grupo de proveedores se marca con fallidos → forzará abierto.
const todoFallo = classifyActions([
  ev('task_provider_failed', { provider: 'A', status: 'empty', total_len: 3 }),
  ev('task_provider_failed', { provider: 'B', status: 'quota' }),
]);
assert('P4: con cero oks los proveedores se marcan como fallidos', todoFallo.proveedoresFallidos === 2, String(todoFallo.proveedoresFallidos));

// ── B1: el resumen de proveedores cuenta los `provider_failed` de live_worker ─
//
// Orden 159 real (runtime.db, eventos 22811-22813): el intento de streaming del
// selector de herramientas murió en `provider_failed` con status=empty y luego
// hubo provider_fallback + provider_exhausted. Después, superagent despachó las
// tareas con el MISMO proveedor y emitió task_provider_ok. Antes esto se veía
// como "1 probado · 0 fallaron" porque classifyActions solo escuchaba
// task_provider_* y se tragaba el provider_failed de live_worker.
const orden159 = [
  ev('provider_failed', { provider: 'OpenCode', model: 'deepseek-v4-flash-free', status: 'empty' }),
  ev('provider_fallback', { to_provider: 'OpenCode', to_model: 'deepseek-v4-flash-free', status: 'empty' }),
  ev('provider_exhausted', { providers_tried: 1, message: 'all providers exhausted – no LLM response available' }),
  ev('task_started', { task_id: 't1', department: 'programacion', task_type: 'programar', description: 'Implementar la solución conforme a la orden' }),
  ev('task_provider_ok', { task_id: 't1', provider: 'OpenCode', model: 'deepseek-v4-flash-free', status: 'ok', key_label: 'OPENCODE_01' }),
  ev('file_written', { task_id: 't1', file_path: 'orden-159\\t1.py' }),
  ev('task_done', { task_id: 't1', worker_id: 't1', success: true, model_used: 'deepseek-v4-flash-free', integrated: true }),
  ev('order_failed', { completed: 0, failed: 2, cause: 'all_tasks_failed' }),
];
const b159 = classifyActions(orden159);
console.log('\nB1 (orden 159 real):');
console.log('  proveedores:', b159.proveedores.length, 'distintos:', b159.proveedoresDistintos, 'fallidos:', b159.proveedoresFallidos, '| fallbacks:', b159.fallbacks);
assert('B1: el provider_failed de live_worker cuenta como proveedor', b159.proveedores.some((pr) => pr.titulo.startsWith('OpenCode') && !pr.ok), '');
assert('B1: 1 proveedor distinto (OpenCode)', b159.proveedoresDistintos === 1, String(b159.proveedoresDistintos));
assert('B1: 1 proveedor fallido (no 0)', b159.proveedoresFallidos === 1, String(b159.proveedoresFallidos));
assert('B1: 1 fallback', b159.fallbacks === 1, String(b159.fallbacks));
assert('B1: fallo del proveedor visible con su causa', b159.proveedores.some((pr) => pr.detalle.includes('no devolvió texto')), JSON.stringify(b159.proveedores));
assert('B1: task_provider_ok del MISMO proveedor NO dobla el conteo', b159.proveedoresDistintos === 1, String(b159.proveedoresDistintos));
assert('B1: provider_exhausted captura el primer error', !!b159.primerError && b159.primerError.detalle.includes('all providers exhausted'), b159.primerError && b159.primerError.detalle);

// ── B2: la píldora de ACTIVIDAD sigue el estado TERMINAL real, no `dispatch.ok` ─
//
// Orden 159 real: dispatch.ok=true (el hilo terminó de despachar) pero
// orders.status='failed' y la traza acaba en order_failed cause=all_tasks_failed.
// El panel lateral mostró "done" porque solo miraba poll.ok. La fase debe salir
// del estado que el motor sincronizó (DaOrderStatus: done=5, failed=6,
// rejected=7, cancelled=9).
assert('B2: failed con dispatch.ok=true NUNCA es done', terminalOrderPhase(true, 6) === 'error', terminalOrderPhase(true, 6));
assert('B2: rejected con dispatch.ok=true es error', terminalOrderPhase(true, 7) === 'error', terminalOrderPhase(true, 7));
assert('B2: cancelled es cancelled, no done ni "errores"', terminalOrderPhase(true, 9) === 'cancelled', terminalOrderPhase(true, 9));
assert('B2: done real sigue siendo done', terminalOrderPhase(true, 5) === 'done', terminalOrderPhase(true, 5));
assert('B2: sin estado consultable, dispatch.ok manda (done)', terminalOrderPhase(true, null) === 'done', terminalOrderPhase(true, null));
assert('B2: sin estado y dispatch.ok=false es error', terminalOrderPhase(false, null) === 'error', terminalOrderPhase(false, null));

// ── P7: el plan hecho por el planner LOCAL se anuncia, no se oculta ─────────
//
// Entre la orden 106 y la 113 las órdenes de construcción pasaron a ser
// planificadas por planner.zig (fallback sin LLM) y hasta la UI no decía nada,
// así que el usuario creía que un modelo había planificado su orden. Con el
// evento planner_fallback, la tarjeta siempre visible lo cuenta.
const conMock = classifyActions([
  ev('planner_fallback', { reason: 'mock_planner' }),
  ev('task_started', { task_id: 't1', department: 'programacion', task_type: 'programar', description: 'x' }),
]);
assert('P7: planner_fallback produce una tarjeta fija visible', conMock.fijos.some((f) => f.titulo.includes('MockPlanner')), JSON.stringify(conMock.fijos));
assert('P7: la etiqueta dice que no hubo LLM', conMock.fijos.some((f) => f.detalle.includes('modelo LLM')), '');
assert('P7: sin evento no hay etiqueta', !classifyActions([ev('task_started', { task_id: 't1' })]).fijos.some((f) => f.titulo.includes('MockPlanner')), '');

// Cuando ni siquiera hay error que contar ni archivos, empieza en vacío.
const vacio = classifyActions([]);
assert('P4: sin eventos no hay nada que agrupar', vacio.fijos.length === 0 && vacio.proveedores.length === 0, '');

// ── S7: la tarjeta de archivo escrito trae la ruta para poder abrirlo ────

const s7 = classifyActions([
  {
    id: 1, ts: 0, source: 'superagente', kind: 'file_written',
    payload: { file_path: 'C:\\Workspace\\x\\proy\\orden-9\\index.html', task_id: 't1' },
  },
]);
const tarjetaArchivo = s7.fijos.find((f) => /Escribió/.test(f.titulo));
assert('S7 la tarjeta de archivo existe', !!tarjetaArchivo, JSON.stringify(s7.fijos));
assert(
  'S7 la tarjeta trae la ruta absoluta en `abrir`',
  tarjetaArchivo && tarjetaArchivo.abrir === 'C:\\Workspace\\x\\proy\\orden-9\\index.html',
  tarjetaArchivo && tarjetaArchivo.abrir
);
assert(
  'S7 el titulo sigue mostrando solo el nombre del archivo',
  tarjetaArchivo && tarjetaArchivo.titulo === 'Escribió index.html',
  tarjetaArchivo && tarjetaArchivo.titulo
);

// Una tarjeta que NO es de archivo no debe traer `abrir`: el boton solo tiene
// sentido cuando hay algo que abrir.
const s7b = classifyActions([
  { id: 1, ts: 0, source: 'superagente', kind: 'order_done', payload: { completed: 1, failed: 0 } },
]);
assert(
  'S7 una tarjeta que no es de archivo no trae `abrir`',
  s7b.fijos.every((f) => f.abrir === undefined),
  JSON.stringify(s7b.fijos)
);


// Eventos reales de la orden 436: el stream no se duplica como tarjeta;
// solo queda la terminación, plegada si salió bien o visible si falló.
const comandos436 = classifyActions([
  ev('shell_command', { command: 'node', file: 'app.js', status: 'running' }),
  ev('shell_command', { chunk: 'progreso\n', status: 'delta' }),
  ev('shell_command', { command: 'node', file: 'app.js', status: 'done', exit_code: 0, stdout: 'ok\n', stderr: '' }),
  ev('shell_command', { command: 'node', file: 'test_app.js', status: 'done', exit_code: 1, stdout: 'salida\n', stderr: 'falló\n' }),
]);
assert('V9: running/delta no crean tarjetas vacías', comandos436.fijos.length === 1 && comandos436.verificaciones.length === 1, JSON.stringify(comandos436));
assert('V9: exit 0 se pliega como verificación', comandos436.verificaciones[0]?.titulo === 'Comando correcto: node app.js', JSON.stringify(comandos436.verificaciones));
assert('V9: fallo final visible conserva exit y salida', comandos436.fijos[0]?.detalle.includes('Código de salida: 1') && comandos436.fijos[0]?.detalle.includes('salida') && comandos436.fijos[0]?.detalle.includes('falló'), JSON.stringify(comandos436.fijos));
const unknownExit = classifyActions([ev('shell_command', { command: 'node', status: 'done', exit_code: null })]);
assert('V9: exit null no equivale a éxito', unknownExit.verificaciones.length === 0 && unknownExit.fijos[0]?.detalle.includes('no informado'));
const timeoutExit = classifyActions([ev('shell_command', { command: 'node', status: 'done', exit_code: 0, timed_out: true })]);
assert('V9: tiempo agotado queda explícito sin inventar fallo de proceso', timeoutExit.fijos[0]?.titulo === 'Comando detenido por tiempo: node' && timeoutExit.verificaciones.length === 0);
const comandoLegacy = classifyActions([ev('shell_command', { command: 'node', file: 'legado.js' })]);
assert('V9: comando legacy con destino permanece visible', comandoLegacy.fijos[0]?.titulo === 'Ejecutó node legado.js', JSON.stringify(comandoLegacy.fijos));
const engineExit = "exit=1\nevalmachine.<anonymous>:15\nError: Operación inválida\n    at calculate (app.js:15:13)";
const technicalMessage = classifyActions([ev('agent_message', { text: engineExit })]);
assert('V10: error técnico del motor tiene resumen rojo breve', technicalMessage.fijos[0]?.titulo === 'Proceso falló (exit=1)' && technicalMessage.fijos[0]?.color === 'var(--danger)', JSON.stringify(technicalMessage.fijos));
assert('V10: error técnico conserva stack completo en detalle', technicalMessage.fijos[0]?.detalle === engineExit, JSON.stringify(technicalMessage.fijos));
const conversationMessage = classifyActions([ev('agent_message', { text: 'El modelo explicó el resultado completo.' })]);
assert('V10: conversación sin protocolo técnico no se resume', conversationMessage.fijos[0]?.titulo === 'El modelo explicó el resultado completo.' && conversationMessage.fijos[0]?.detalle === '', JSON.stringify(conversationMessage.fijos));
console.log(failed === 0 ? '\nTODO MENOS: TEST PASÓ' : `\n${failed} FALLOS`);
process.exit(failed === 0 ? 0 : 1);
