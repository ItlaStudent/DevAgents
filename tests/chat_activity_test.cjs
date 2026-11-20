// Prueba de la divulgación progresiva del chat agéntico (CHAT-PD-1).
// node tests/chat_activity_test.cjs
const {
  construirActividad,
  resumenActividad,
  deberiaPlegarse,
  bloqueosVigentes,
  formatearDuracion,
  canalDe,
  consolasDeWorkers,
  textoDeBytes,
} = require('../shell/webui/dist/chat_activity.test.cjs');

let failed = 0;
function assert(name, cond, detail) {
  if (cond) {
    console.log(`  ok: ${name}`);
  } else {
    failed += 1;
    console.error(`  FAIL: ${name} ${detail ? '-> ' + detail : ''}`);
  }
}

let seq = 0;
function ev(kind, payload, ts) {
  seq += 1;
  return { id: seq, ts: ts === undefined ? seq * 1000 : ts, source: 'motor', kind, payload };
}

// Instantes de época reales: un `ts` que no puede ser una fecha no mide nada.
const BASE = 1788856878000;
const VIVO = { ahora: BASE + 100000, vivo: true };
const MUERTO = { ahora: BASE + 100000, vivo: false };

// ── Canales: la clasificación es por kind, no por texto libre ────────────

assert('el mensaje del agente es respuesta final', canalDe('agent_message') === 'respuesta');
assert('el delta de contenido es diagnóstico, no respuesta', canalDe('content_delta') === 'diagnostico');
assert('el razonamiento tiene canal propio', canalDe('reasoning_delta') === 'razonamiento');
assert('un comando es una operación', canalDe('shell_command') === 'operacion');
assert('un kind desconocido NO se clasifica a ciegas', canalDe('kind_del_futuro') === 'desconocido');
assert('la corriente del worker es diagnostico, no un fallo aparte', canalDe('worker_output') === 'diagnostico');

// ── Streaming: una operación, una tarjeta ───────────────────────────────

seq = 0;
const streaming = construirActividad(
  [
    // Contrato real del motor: `command` es la línea efectiva COMPLETA
    // (exe + argv renderizado), `file` solo aparece en la ruta archivo y el
    // delta la repite para correlacionar. `chunk` lleva el trozo en vivo.
    ev('shell_command', { task_id: 't5', command: 'node test_app.js', file: 'test_app.js', status: 'running' }),
    ev('shell_command', { task_id: 't5', command: 'node test_app.js', status: 'delta', stream: 'stdout', chunk: 'a' }),
    ev('shell_command', { task_id: 't5', command: 'node test_app.js', status: 'delta', stream: 'stdout', chunk: 'b' }),
    ev('shell_command', { task_id: 't5', command: 'node test_app.js', status: 'delta', stream: 'stderr', chunk: 'warn\n' }),
    ev('shell_command', {
      task_id: 't5', command: 'node test_app.js', file: 'test_app.js', status: 'done',
      exit_code: 1, stdout: 'salida', stderr: 'Assertion failed',
    }),
  ],
  VIVO
);
assert('cinco eventos de un comando son UNA operación', streaming.operaciones.length === 1, JSON.stringify(streaming.operaciones));
assert('la operación conserva cuántos eventos plegó', streaming.operaciones[0].eventos === 5);
assert('el estado final del comando es fallo', streaming.operaciones[0].estado === 'fallo');
assert('el código de salida real se conserva', streaming.operaciones[0].exitCode === 1);
assert('el título no se pierde al llegar el último trozo', streaming.operaciones[0].titulo === 'Ejecutó node test_app.js');
assert('un comando NO se le atribuye a un modelo', streaming.operaciones[0].atribucion === 'Ejecutor local');

// B1/G2: el delta en vivo alimenta la card ANTES del done (la salida se ve
// mientras el proceso corre, no de golpe al final).
seq = 0;
const enVivo = construirActividad(
  [
    ev('shell_command', { task_id: 't6', command: 'powershell -NoProfile -Command "1..3 | % { \'tick \' + $_ }"', status: 'running' }),
    ev('shell_command', { task_id: 't6', command: 'powershell -NoProfile -Command "1..3 | % { \'tick \' + $_ }"', status: 'delta', stream: 'stdout', chunk: 'tick 1\r\n' }),
    ev('shell_command', { task_id: 't6', command: 'powershell -NoProfile -Command "1..3 | % { \'tick \' + $_ }"', status: 'delta', stream: 'stdout', chunk: 'tick 2\r\n' }),
  ],
  VIVO
);
assert('los deltas correlacionan con la card del running', enVivo.operaciones.length === 1, JSON.stringify(enVivo.operaciones));
assert('la card en vivo lleva etiqueta activa', enVivo.operaciones[0].titulo.startsWith('Ejecutando '), enVivo.operaciones[0].titulo);
assert('la card muestra la línea efectiva completa', enVivo.operaciones[0].titulo.includes('-Command'), enVivo.operaciones[0].titulo);
assert('el stdout se acumula mientras corre', enVivo.operaciones[0].stdout === 'tick 1\r\ntick 2\r\n', JSON.stringify(enVivo.operaciones[0].stdout));

// ── El éxito no se infiere de que dejara de emitir ───────────────────────

seq = 0;
const eventosSinCierre = [
  ev('task_started', { task_id: 't1', department: 'programacion', description: 'index.html' }),
  ev('file_written', { task_id: 't1', file_path: 'C:\\ws\\orden-9\\index.html' }),
];
const vivo = construirActividad(eventosSinCierre, VIVO);
assert('mientras emite, el turno está ejecutando', vivo.estado === 'ejecutando', vivo.estado);
const cortado = construirActividad(eventosSinCierre, MUERTO);
assert('sin evento terminal el turno queda INTERRUMPIDO, no completado', cortado.estado === 'interrumpido', cortado.estado);
assert('una tarea sin cierre no se marca ok', cortado.operaciones.find((o) => o.id === 'tarea:t1').estado === 'sin_ejecutar');

seq = 0;
const cancelado = construirActividad([ev('task_started', { task_id: 't1' }), ev('order_cancelled', {})], MUERTO);
assert('cancelado se distingue de fallido', cancelado.estado === 'cancelado');
seq = 0;
const fallido = construirActividad([ev('order_failed', { cause: 'all_tasks_failed' })], MUERTO);
assert('fallido se distingue de completado', fallido.estado === 'fallido');
seq = 0;
const completado = construirActividad([ev('order_done', { completed: 3, failed: 0 })], MUERTO);
assert('completado exige su evento terminal', completado.estado === 'completado');

// ── Resumen plegado: cuenta acciones, no eventos ────────────────────────

seq = 0;
const turno437 = construirActividad(
  [
    ev('superagent_thinking', { text: 'Ola 1 de 4: ejecutando 1 tarea(s) en paralelo…' }, BASE + 0),
    ev('task_started', { task_id: 't1', department: 'programacion', description: 'index.html', provider: 'Cohere', model: 'command-r-plus-08-2024' }, BASE + 1000),
    ev('file_written', { task_id: 't1', file_path: 'C:\\ws\\orden-437\\index.html' }, BASE + 2000),
    ev('task_done', { task_id: 't1', success: true, model_used: 'command-r-plus-08-2024' }, BASE + 3000),
    ev('task_started', { task_id: 't3', department: 'programacion', description: 'app.js' }, BASE + 4000),
    ev('file_written', { task_id: 't3', file_path: 'C:\\ws\\orden-437\\app.js' }, BASE + 5000),
    ev('task_done', { task_id: 't3', success: true }, BASE + 6000),
    ev('shell_command', { task_id: 't5', command: 'node', file: 'test_app.js', status: 'done', exit_code: 1, stderr: 'DOM simulado' }, BASE + 7000),
    ev('test_evidence_v1', { producer_task_id: 't3', ran: true, exit_code: 1, command: 'node test_app.js', stderr: 'DOM simulado' }, BASE + 8000),
    ev('browser_gate_v1', {
      ran: true, verdict: 'fail', page: 'index.html', browser: 'msedge', files_checked: 4,
      dead_controls: 1,
      controls: [
        { control: 'button#calculate "Calcular"', changed_dom: false, errors: 0 },
        { control: 'button#clear "Borrar"', changed_dom: true, errors: 0 },
      ],
    }, BASE + 9000),
    ev('order_failed', { cause: 'browser_gate_failed' }, BASE + 135000),
  ],
  MUERTO
);
assert('el resumen dice cuánto trabajó', resumenActividad(turno437).includes('Falló tras 2 min 15 s'), resumenActividad(turno437));
assert('el resumen cuenta acciones, no eventos', resumenActividad(turno437).includes('7 acciones'), resumenActividad(turno437));
assert('el transcurrido sale de los eventos reales', turno437.transcurridoMs === 135000);
// La traza real de la 437 trae `ts` 1..5 en sus primeros eventos: relleno del
// exportador, no instantes. Medir desde ahí daba duraciones absurdas.
seq = 0;
const conRellenoDeTs = construirActividad(
  [
    ev('worker_output', { task_id: 't5', text: 'ruido' }, 1),
    ev('task_started', { task_id: 't1' }, BASE + 1000),
    ev('order_done', {}, BASE + 31000),
  ],
  MUERTO
);
assert('un ts imposible no cuenta como el arranque del turno', conRellenoDeTs.transcurridoMs === 30000, String(conRellenoDeTs.transcurridoMs));
const etiquetas = turno437.grupos.map((g) => g.etiqueta);
assert('agrupa las tareas', etiquetas.includes('Ejecutó 2 tareas'), JSON.stringify(etiquetas));
assert('agrupa los archivos escritos', etiquetas.includes('Escribió 2 archivos'), JSON.stringify(etiquetas));
assert('agrupa el comando', etiquetas.includes('Ejecutó 1 comando'), JSON.stringify(etiquetas));
assert('nombra la comprobación de navegador', etiquetas.includes('Comprobó la página en un navegador'), JSON.stringify(etiquetas));

// ── Bloqueos: visibles, deduplicados y con acción ───────────────────────

const vigentes = bloqueosVigentes(turno437);
assert('el control muerto de la 437 es un bloqueo visible', vigentes.some((b) => b.detalle.includes('button#calculate')), JSON.stringify(vigentes));
assert('el bloqueo nombra solo el control que NO reacciona', !vigentes.some((b) => b.detalle.includes('button#clear')), JSON.stringify(vigentes));
// Con bloqueos concretos, «la orden falló» no se repite como uno más: el
// titular ya lo dice el estado del turno.
assert('el fallo de la orden no se repite como bloqueo suelto', !vigentes.some((b) => b.titulo === 'La orden terminó con errores'), JSON.stringify(vigentes));
assert('el bloqueo que encabeza es el del comando real', vigentes[0].titulo.startsWith('Comando falló'), JSON.stringify(vigentes[0]));
assert('cada bloqueo ofrece una acción', vigentes.every((b) => b.accion.length > 0));

// Una tarea que falla PORQUE su dependencia falló es consecuencia, no bloqueo.
seq = 0;
const arrastre = construirActividad(
  [
    ev('task_failed', { task_id: 't2', success: false, cause: 'validation_failed', error_msg: 'falta filename' }),
    ev('task_failed', { task_id: 't5', success: false, cause: 'dependency_failed', error_msg: 'dependency failed or missing' }),
    ev('task_failed', { task_id: 't6', success: false, cause: 'dependency_failed', error_msg: 'dependency failed or missing' }),
    ev('order_failed', { cause: 'all_tasks_failed' }),
  ],
  MUERTO
);
assert('el arrastre no multiplica bloqueos', bloqueosVigentes(arrastre).length === 1, JSON.stringify(bloqueosVigentes(arrastre)));
assert('la causa raiz es la que queda', bloqueosVigentes(arrastre)[0].titulo === 'Tarea t2 fallida');
assert('las tareas arrastradas siguen marcadas como fallidas', arrastre.operaciones.filter((o) => o.estado === 'fallo').length === 3);
seq = 0;
const soloLaOrden = construirActividad([ev('order_failed', { cause: 'planner_empty' })], MUERTO);
assert('si no hay nada mas concreto, el fallo de la orden si se declara', bloqueosVigentes(soloLaOrden).length === 1);

// Incidencia real: plan local + modelo fijado sin clave. El bloqueo de
// planner_fallback existía, la causa terminal (selected_model_unavailable)
// se escondía y el usuario solo veía «El plan no lo generó un modelo».
seq = 0;
const planLocalSinModelo = construirActividad(
  [
    ev('planner_fallback', { reason: 'mock_planner', detail: 'el modelo fijado no tiene un candidato con clave activa' }),
    ev('order_failed', { cause: 'selected_model_unavailable' }),
  ],
  MUERTO
);
const vigentesPlanLocal = bloqueosVigentes(planLocalSinModelo);
assert(
  'una causa de nivel orden se muestra aunque ya haya bloqueos',
  vigentesPlanLocal.some((b) => b.titulo === 'El modelo elegido no está disponible'),
  JSON.stringify(vigentesPlanLocal)
);
assert(
  'el fallback del planner muestra la causa real, no el código',
  vigentesPlanLocal.some((b) => b.detalle.includes('clave activa')),
  JSON.stringify(vigentesPlanLocal)
);
seq = 0;
const planLocalLegado = construirActividad([ev('planner_fallback', { reason: 'mock_planner' })], MUERTO);
assert(
  'un planner_fallback antiguo sin detail se traduce, no muestra el código',
  bloqueosVigentes(planLocalLegado).some((b) => b.detalle.includes('planificador local') && !b.detalle.includes('mock_planner')),
  JSON.stringify(bloqueosVigentes(planLocalLegado))
);

seq = 0;
const duplicado = construirActividad(
  [
    ev('task_failed', { task_id: 't2', success: false, cause: 'execution_failed', error_msg: 'exit 1' }),
    ev('task_failed', { task_id: 't2', success: false, cause: 'execution_failed', error_msg: 'exit 1' }),
  ],
  MUERTO
);
assert('el mismo fallo no se cuenta dos veces', duplicado.bloqueos.length === 1, JSON.stringify(duplicado.bloqueos));

seq = 0;
const recuperado = construirActividad(
  [
    ev('task_failed', { task_id: 't3', success: false, cause: 'validation_failed', error_msg: 'faltaba el manejador' }),
    ev('task_done', { task_id: 't3', success: true }),
    ev('order_done', { completed: 1, failed: 0 }),
  ],
  MUERTO
);
assert('un fallo recuperado se conserva marcado como resuelto', recuperado.bloqueos.length === 1 && recuperado.bloqueos[0].resuelto === true, JSON.stringify(recuperado.bloqueos));
assert('un fallo recuperado deja de reclamar atención', bloqueosVigentes(recuperado).length === 0);

// ── Plegado automático y respeto por lo pendiente ───────────────────────

assert('un turno vivo NO se pliega solo', deberiaPlegarse(vivo) === false);
assert('un turno terminado se pliega solo', deberiaPlegarse(turno437) === true);
seq = 0;
const conAprobacion = construirActividad(
  [
    ev('task_started', { task_id: 't1' }),
    ev('approval_needed', { exe: 'python', reason: 'ejecutar un artefacto requiere aprobación' }),
  ],
  VIVO
);
assert('una aprobación pendiente cambia el estado a esperando', conAprobacion.estado === 'esperando', conAprobacion.estado);
assert('con aprobación pendiente el bloque NO se pliega', deberiaPlegarse(conAprobacion) === false);
assert('la aprobación queda a la vista', conAprobacion.pendientes.length === 1);

// (tanda 1): la tarjeta lleva el id para contestarla desde el hilo
// y desaparece cuando el motor registra la respuesta o el cierre.
seq = 0;
const conId = construirActividad(
  [ev('task_started', { task_id: 't1' }), ev('approval_needed', { approval_id: 7, tool: 'run_command', reason: 'Aprobar este comando exacto' })],
  VIVO
);
assert('la aprobación pendiente lleva su id', conId.pendientes[0] && conId.pendientes[0].approvalId === 7, JSON.stringify(conId.pendientes));
seq = 0;
const contestada = construirActividad(
  [
    ev('task_started', { task_id: 't1' }),
    ev('approval_needed', { approval_id: 7, tool: 'run_command' }),
    ev('approval_needed', { approval_id: 8, tool: 'run_command' }),
    ev('approval_resolved', { approval_id: 7, approved: true }),
  ],
  VIVO
);
assert('una aprobación contestada deja el hilo', contestada.pendientes.length === 1 && contestada.pendientes[0].approvalId === 8, JSON.stringify(contestada.pendientes));
assert('approval_resolved no es un evento desconocido', !contestada.desconocidos.some((d) => d.kind === 'approval_resolved'));
seq = 0;
const cerrada = construirActividad(
  [ev('approval_needed', { approval_id: 9 }), ev('approval_closed', { approval_id: 9, reason: 'orden terminada' })],
  VIVO
);
assert('una aprobación cerrada por el motor deja el hilo', cerrada.pendientes.length === 0 && cerrada.estado !== 'esperando', cerrada.estado);
seq = 0;
const caducada = construirActividad(
  [ev('approval_needed', { approval_id: 10 }), ev('order_failed', { cause: 'execution_failed' })],
  MUERTO
);
assert('un turno terminado no sigue pidiendo aprobación', caducada.pendientes.length === 0, JSON.stringify(caducada.pendientes));

// La gobernanza no pide permiso: impide. Es un bloqueo, no una aprobación.
seq = 0;
const bloqueoDeGobernanza = construirActividad(
  [ev('governance_blocked_v1', { reason: 'Free bloquea el modelo fijado; no se envio la solicitud' })],
  MUERTO
);
assert('el bloqueo de gobernanza se declara con su razon', bloqueosVigentes(bloqueoDeGobernanza)[0].detalle.includes('Free bloquea el modelo fijado'), JSON.stringify(bloqueoDeGobernanza.bloqueos));
assert('el bloqueo de gobernanza no se disfraza de aprobacion', bloqueoDeGobernanza.pendientes.length === 0);

// BUDGET-1: sin autorizacion de gasto, el chat lo dice y ofrece la salida.
seq = 0;
const sinPresupuesto = construirActividad(
  [ev('budget_blocked_v1', { reason: 'No hay llamadas de pago autorizadas; no se envio la solicitud', model: 'OpenCode/gpt-5.5-pro' })],
  MUERTO
);
const bloqueoPresupuesto = bloqueosVigentes(sinPresupuesto)[0];
assert('el bloqueo de presupuesto se declara', bloqueoPresupuesto.titulo === 'Cupo de llamadas de pago agotado', JSON.stringify(bloqueoPresupuesto));
assert('el bloqueo de presupuesto nombra el modelo', bloqueoPresupuesto.detalle.includes('OpenCode/gpt-5.5-pro'), bloqueoPresupuesto.detalle);
assert('el bloqueo de presupuesto ofrece la accion', bloqueoPresupuesto.accion.includes('Autorizar más llamadas'), bloqueoPresupuesto.accion);

// Los campos reales de una herramienta nativa: tool_name / exit_code / timed_out.
seq = 0;
const herramienta = construirActividad(
  [
    ev('native_tool_result_v1', { tool_name: 'run_command', task_id: 't1', exit_code: 0, stdout: 'archivo creado', stderr: '', timed_out: false }),
    ev('native_tool_result_v1', { tool_name: 'run_command', task_id: 't2', exit_code: 2, stdout: 'salida parcial', stderr: 'permiso denegado', timed_out: false }),
    ev('native_tool_result_v1', { tool_name: 'run_command', task_id: 't3', exit_code: 0, stdout: 'demasiado tarde', stderr: '', timed_out: true }),
  ],
  MUERTO
);
const titulosHerramienta = herramienta.operaciones.map((o) => o.titulo);
assert('la herramienta correcta lo dice', titulosHerramienta.includes('run_command terminó correctamente'), JSON.stringify(titulosHerramienta));
assert('la herramienta fallida conserva su código', titulosHerramienta.includes('run_command terminó con código 2'), JSON.stringify(titulosHerramienta));
assert('el tiempo agotado no se anuncia como éxito', titulosHerramienta.includes('run_command superó el tiempo límite') && !herramienta.operaciones.some((o) => o.taskId === 't3' && o.estado === 'ok'), JSON.stringify(titulosHerramienta));
assert('la salida de la herramienta se conserva', herramienta.operaciones.some((o) => (o.stderr || '').includes('permiso denegado')));

// La revisión del productor ata la prueba a unos bytes concretos.
seq = 0;
const qa = construirActividad(
  [ev('test_evidence_v1', { task_id: 'qa', producer_task_id: 'app', producer_revision: '18ac02', command: 'node test_app.js', ran: true, exit_code: 1, stdout: '2+3=3', stderr: 'Expected 5', timed_out: false })],
  MUERTO
);
assert('la prueba fallida dice su código', qa.operaciones[0].titulo === 'Pruebas de app: falló (código 1)', qa.operaciones[0].titulo);
assert('la prueba conserva comando y revisión', qa.operaciones[0].detalle.includes('node test_app.js') && qa.operaciones[0].detalle.includes('18ac02'), qa.operaciones[0].detalle);
seq = 0;
const qaSinCorrer = construirActividad(
  [ev('test_evidence_v1', { producer_task_id: 'app', producer_revision: '18ac02', command: 'node test_app.js', ran: false, exit_code: 0 })],
  MUERTO
);
assert('exit_code 0 sin ejecutar NO es una prueba pasada', qaSinCorrer.operaciones[0].titulo === 'Pruebas de app: sin ejecutar' && qaSinCorrer.operaciones[0].estado === 'sin_ejecutar', qaSinCorrer.operaciones[0].titulo);

// ── Razonamiento: sólo el que entrega la API, con su procedencia ─────────

seq = 0;
const sinRazonamiento = construirActividad([ev('agent_message', { text: 'listo' }), ev('order_done', {})], MUERTO);
assert('sin razonamiento del proveedor no se inventa ninguno', sinRazonamiento.razonamiento === null);
seq = 0;
const conRazonamiento = construirActividad(
  [
    ev('reasoning_delta', { text: 'primero ', provider: 'Anthropic', model: 'claude' }),
    ev('reasoning_delta', { text: 'después' }),
    ev('order_done', {}),
  ],
  MUERTO
);
assert('el razonamiento se concatena entero', conRazonamiento.razonamiento.texto === 'primero después');
assert('el razonamiento declara su procedencia real', conRazonamiento.razonamiento.procedencia === 'Anthropic · claude');
seq = 0;
const razonamientoAnonimo = construirActividad([ev('reasoning_delta', { text: 'algo' })], MUERTO);
assert('sin procedencia declarada se dice, no se inventa', razonamientoAnonimo.razonamiento.procedencia.includes('no declarada'));

// ── Compatibilidad: lo dudoso se enseña, no se esconde ──────────────────

seq = 0;
const antiguo = construirActividad(
  [ev('evento_de_una_version_vieja', { algo: 'que importa' }), ev('order_done', {})],
  MUERTO
);
assert('un kind desconocido se conserva visible', antiguo.desconocidos.length === 1, JSON.stringify(antiguo.desconocidos));
assert('el contenido del kind desconocido no se pierde', antiguo.desconocidos[0].texto.includes('que importa'));

// ── Operaciones sin ejecutar no se atribuyen a nadie ─────────────────────

seq = 0;
const saltado = construirActividad(
  [ev('exec_skipped', { task_id: 't3', file: 'app.js', razon: 'js_de_navegador_no_se_ejecuta_con_node' }), ev('order_done', {})],
  MUERTO
);
const opSaltada = saltado.operaciones[0];
assert('lo no ejecutado se dice y no se cuelga de un proveedor', opSaltada.estado === 'sin_ejecutar' && opSaltada.atribucion === 'Sin ejecutar', JSON.stringify(opSaltada));

// ── Reapertura: los mismos eventos, la misma agrupación ─────────────────

const reabierto = construirActividad(
  [
    ev('superagent_thinking', { text: 'Ola 1 de 4: ejecutando 1 tarea(s) en paralelo…' }, BASE + 0),
    ev('task_started', { task_id: 't1', department: 'programacion', description: 'index.html', provider: 'Cohere', model: 'command-r-plus-08-2024' }, BASE + 1000),
    ev('file_written', { task_id: 't1', file_path: 'C:\\ws\\orden-437\\index.html' }, BASE + 2000),
    ev('task_done', { task_id: 't1', success: true, model_used: 'command-r-plus-08-2024' }, BASE + 3000),
    ev('task_started', { task_id: 't3', department: 'programacion', description: 'app.js' }, BASE + 4000),
    ev('file_written', { task_id: 't3', file_path: 'C:\\ws\\orden-437\\app.js' }, BASE + 5000),
    ev('task_done', { task_id: 't3', success: true }, BASE + 6000),
    ev('shell_command', { task_id: 't5', command: 'node', file: 'test_app.js', status: 'done', exit_code: 1, stderr: 'DOM simulado' }, BASE + 7000),
    ev('test_evidence_v1', { producer_task_id: 't3', ran: true, exit_code: 1, command: 'node test_app.js', stderr: 'DOM simulado' }, BASE + 8000),
    ev('browser_gate_v1', {
      ran: true, verdict: 'fail', page: 'index.html', browser: 'msedge', files_checked: 4, dead_controls: 1,
      controls: [
        { control: 'button#calculate "Calcular"', changed_dom: false, errors: 0 },
        { control: 'button#clear "Borrar"', changed_dom: true, errors: 0 },
      ],
    }, BASE + 9000),
    ev('order_failed', { cause: 'browser_gate_failed' }, BASE + 135000),
  ],
  MUERTO
);
assert('al reabrir la conversación el resumen es idéntico', resumenActividad(reabierto) === resumenActividad(turno437), `${resumenActividad(reabierto)} vs ${resumenActividad(turno437)}`);
assert('al reabrir se conservan los mismos bloqueos', bloqueosVigentes(reabierto).length === bloqueosVigentes(turno437).length);

// ── Auditoría de cabina 09-09: lo dudoso se ve y no colapsa ─────────────

seq = 0;
const sinDestino = construirActividad(
  [ev('shell_command', { task_id: 't9', status: 'done', exit_code: 1 }), ev('order_done', {})],
  MUERTO
);
assert('un shell_command sin command ni file se conserva visible', sinDestino.desconocidos.length === 1, JSON.stringify(sinDestino));

seq = 0;
const dosComandos = construirActividad(
  [
    ev('shell_command', { task_id: 't1', command: 'node', file: 't.js', status: 'done', exit_code: 1, stderr: 'Assertion failed' }),
    ev('shell_command', { task_id: 't2', command: 'node', file: 't.js', status: 'done', exit_code: 1, stderr: 'Assertion failed' }),
    ev('order_failed', { cause: 'test_failed' }),
  ],
  MUERTO
);
assert('dos comandos iguales en tareas distintas NO colapsan en uno', dosComandos.bloqueos.length === 2, JSON.stringify(dosComandos.bloqueos));

seq = 0;
const mismoComandoDosVeces = construirActividad(
  [
    ev('shell_command', { task_id: 't1', command: 'node', file: 't.js', status: 'done', exit_code: 1, stderr: 'Assertion failed' }),
    ev('shell_command', { task_id: 't1', command: 'node', file: 't.js', status: 'done', exit_code: 1, stderr: 'Assertion failed' }),
    ev('order_failed', { cause: 'test_failed' }),
  ],
  MUERTO
);
assert('el MISMO fallo repetido dentro de una tarea sí se deduplica', mismoComandoDosVeces.bloqueos.length === 1, JSON.stringify(mismoComandoDosVeces.bloqueos));

assert('previewAvailable tiene canal declarado', canalDe('previewAvailable') === 'operacion');
seq = 0;
const preview = construirActividad(
  [ev('previewAvailable', { task_id: 't7', url: 'http://127.0.0.1:7788/preview' }), ev('order_done', {})],
  MUERTO
);
assert('la vista previa se muestra como operación, no como desconocido', preview.operaciones.length === 1 && preview.desconocidos.length === 0, JSON.stringify(preview));
assert('la operación de vista previa conserva la URL', preview.operaciones[0].detalle.includes('7788'), JSON.stringify(preview.operaciones));

seq = 0;
const gateInvariable = construirActividad(
  [ev('browser_gate_v1', {
    ran: true, verdict: 'pass', page: 'index.html', browser: 'msedge', files_checked: 2,
    dead_controls: 0, controles_invariantes: 1,
    controls: [{ control: 'button#calculate "Calcular"', changed_dom: true, errors: 0, cambio: 'output#result: "" -> "999"', entrada_ignorada: true }],
  }), ev('order_done', {})],
  MUERTO
);
assert('la salida constante del gate se ve en el detalle', gateInvariable.operaciones[0].detalle.includes('misma salida'), JSON.stringify(gateInvariable.operaciones[0]));

// ── Duración legible ────────────────────────────────────────────────────

assert('menos de un minuto se dice en segundos', formatearDuracion(14000) === '14 s');
assert('dos minutos y catorce', formatearDuracion(134000) === '2 min 14 s');
assert('un minuto redondo no arrastra segundos', formatearDuracion(60000) === '1 min');

// ── Consolas paralelas de workers (F3) ───────────────────────────────────
// El motor emite worker_output por trozo y por worker; la consola reagrupa por
// task_id para que doce corrientes se lean por separado, no mezcladas.

seq = 0;
const consolas = consolasDeWorkers([
  ev('worker_output', { task_id: 't1', stream: 'stdout', text: 'tick 1\n', seq: 1 }),
  ev('worker_output', { task_id: 't2', stream: 'stdout', text: 'otro worker\n', seq: 2 }),
  ev('worker_output', { task_id: 't1', stream: 'stdout', text: 'tick 2\n', seq: 3 }),
  ev('worker_output', { worker_id: 'superagente', stream: 'reporte', text: '=== Reporte ===\n', seq: 4 }),
  ev('shell_command', { task_id: 't1', command: 'x', status: 'done' }),
]);
assert('dos tareas producen dos consolas separadas', consolas.filter((c) => c.id === 't1' || c.id === 't2').length === 2, JSON.stringify(consolas.map((c) => c.id)));
assert('los trozos de una tarea concatenan en orden', consolas.find((c) => c.id === 't1').texto === 'tick 1\ntick 2\n', consolas.find((c) => c.id === 't1')?.texto);
assert('sin task_id agrupa por worker_id', consolas.some((c) => c.id === 'superagente'), JSON.stringify(consolas.map((c) => c.id)));
assert('los eventos que no son worker_output no generan consola', consolas.length === 3, consolas.length);
assert('worker_output vacío no abre consola', consolasDeWorkers([ev('worker_output', { task_id: 't9', text: '' })]).length === 0);

const capado = consolasDeWorkers([ev('worker_output', { task_id: 't1', stream: 'stdout', text: 'x'.repeat(70 * 1024) })], 1024);
assert('la consola se capa conservando el final', capado[0].capado === true && capado[0].texto.endsWith('x'.repeat(1024)) === true, capado[0].texto.length);
assert('el capado se declara en el texto', capado[0].texto.includes('truncados'), 'falta marca de truncado');

// ── E2.7: stderr cp850 real — acentos y símbolos de caja ────────────────
// Bytes producidos con el codec cp850 real ('…'.encode('cp850')), no
// inventados: la consola Windows es-ES emite OEM 850 y TextDecoder no lo
// soporta.
const cp850Acentos = [69, 114, 114, 111, 114, 58, 32, 101, 115, 116, 160, 32, 100, 97, 164, 97, 100, 111, 44, 32, 163, 116, 105, 108, 32, 160, 130, 161, 162, 163, 32, 164, 165, 32, 135, 32, 179, 196, 218, 191, 192, 217, 205, 186];
assert(
  'stderr cp850 con acentos decodifica las vocales reales',
  textoDeBytes(cp850Acentos) === 'Error: está dañado, útil áéíóú ñÑ ç │─┌┐└┘═║',
  textoDeBytes(cp850Acentos));
const cp850SoloCaja = [218, 196, 191, 32, 179, 32, 192, 196, 217];
assert('los símbolos de caja no se confunden con letras', textoDeBytes(cp850SoloCaja) === '┌─┐ │ └─┘', textoDeBytes(cp850SoloCaja));
const utf8Bytes = [...'café ✓'].map((c) => c.codePointAt(0)).flatMap((cp) => [...Buffer.from(String.fromCodePoint(cp), 'utf8')]);
assert('un array UTF-8 válido no se desvía a cp850', textoDeBytes(utf8Bytes) === 'café ✓', textoDeBytes(utf8Bytes));
assert('un string normal pasa intacto', textoDeBytes('salida normal') === 'salida normal');
assert('un payload sin números no explota', textoDeBytes(['x', null]) === '');

// ── 22-09: un proveedor agotado del que la orden se recuperó no es bloqueo ──
seq = 0;
const recuperada = construirActividad(
  [
    ev('provider_exhausted', { reason: 'all providers exhausted' }, BASE + 1000),
    ev('order_done', {}, BASE + 2000),
  ],
  MUERTO
);
assert('orden completada: el proveedor agotado intermedio queda resuelto', bloqueosVigentes(recuperada).length === 0, JSON.stringify(recuperada.bloqueos));
assert('el fallo se conserva en la actividad, marcado', recuperada.bloqueos.length === 1 && recuperada.bloqueos[0].resuelto === true);
seq = 0;
const noRecuperada = construirActividad(
  [
    ev('provider_exhausted', { reason: 'all providers exhausted' }, BASE + 1000),
    ev('order_failed', { cause: 'provider_exhausted' }, BASE + 2000),
  ],
  MUERTO
);
assert('orden fallida: el proveedor agotado sigue siendo bloqueo vigente', bloqueosVigentes(noRecuperada).length >= 1);

// ── el reintento por artefacto inválido se ve en la actividad ──
// Un `worker_failed` de artefacto que el motor re-despacha con otro candidato
// no puede quedarse solo en la traza: el Monitor muestra motivo y modelo caído.
seq = 0;
const reintento = construirActividad(
  [
    ev('task_failed', { task_id: 't1', success: false, cause: 'worker_failed', error_msg: 'native worker failed: InvalidArtifact' }, BASE + 1000),
    ev('task_retry', {
      task_id: 't1', cause: 'worker_failed', failed_model: 'modelo-gratis-roto', provider: 'OpenCode',
      assigned_model: 'modelo-gratis-roto', retry_provider: 'OpenRouter', retry_model: 'respaldo-sano',
      reason: 'native worker failed: InvalidArtifact',
    }, BASE + 2000),
    ev('task_done', { task_id: 't1', success: true, model_used: 'respaldo-sano' }, BASE + 3000),
    ev('order_done', { completed: 1, failed: 0 }, BASE + 4000),
  ],
  MUERTO
);
assert('task_retry tiene canal declarado', canalDe('task_retry') === 'operacion');
assert('el reintento se ve como operación, no como desconocido', reintento.desconocidos.length === 0, JSON.stringify(reintento.desconocidos));
assert(
  'el reintento dice motivo y modelo que falló',
  reintento.progreso.some((t) => t === 'Reintento de t1: native worker failed: InvalidArtifact (falló modelo-gratis-roto)'),
  JSON.stringify(reintento.progreso)
);
assert(
  'la operación del reintento conserva motivo y candidato caído',
  reintento.operaciones.some((o) => o.id === 'tarea:t1' && o.detalle.includes('InvalidArtifact') && o.detalle.includes('modelo-gratis-roto')),
  JSON.stringify(reintento.operaciones)
);

// ── 22-09: auditoría impuesta y citas comprobadas ──
seq = 0;
const auditoria = construirActividad(
  [
    ev('plan_audit_enforced_v1', { task_id: 't-auditoria', depends_on: ['t2'] }, BASE + 1000),
    ev('audit_citations_v1', { task_id: 't-auditoria', citas: 3, verificadas: 1, solo_existencia: 0, fallidas: 2, detalle: 'core/src/mcp_server.zig:87 (el texto citado no está en esa línea)' }, BASE + 2000),
  ],
  MUERTO
);
const impuesta = auditoria.operaciones.find((o) => o.id === 'verificacion:auditoria-final');
assert('la auditoría añadida por el motor se ve', !!impuesta && impuesta.titulo === 'El motor añadió la tarea de auditoría', JSON.stringify(auditoria.operaciones));
assert('dice a qué espera', !!impuesta && impuesta.detalle.includes('t2'));
const citas = auditoria.operaciones.find((o) => o.id === 'verificacion:citas:t-auditoria');
assert('las citas falsas se cuentan y se nombran', !!citas && citas.titulo === '2 de 3 citas del auditor no se sostienen' && citas.detalle.includes('mcp_server.zig:87'), JSON.stringify(citas));
assert('y se marcan como fallo, no como aviso', !!citas && citas.estado === 'fallo');

// Snapshot diagnostics are external data, retained in task and terminal blocks.
seq = 0;
const snapshotDetail = 'snapshot: fallo; etapa=apertura; ruta=src/<clock>.py; error=SharingViolation; win32=32';
const snapshotActivity = construirActividad([
  ev('external_agent_finished', { task_id: 't1', success: false, error: snapshotDetail }),
  ev('task_failed', { task_id: 't1', cause: 'worker_failed', error_msg: snapshotDetail }),
  ev('order_failed', { cause: 'all_tasks_failed', reason: snapshotDetail }),
], { ahora: BASE + 5000 });
assert('SNAP UI preserves actionable task diagnosis', snapshotActivity.operaciones.some(o => o.taskId === 't1' && o.detalle === snapshotDetail));
assert('SNAP UI preserves terminal diagnosis', snapshotActivity.bloqueos.some(b => b.detalle.includes(snapshotDetail)));

const dependencyWarning = '3 archivos cambiados en carpetas de dependencias/cachés';
const dependencyActivity = construirActividad([
  ev('external_agent_event', { task_id: 't1', kind: 'warning', text: dependencyWarning }),
  ev('external_agent_event', { task_id: 't1', kind: 'warning', text: dependencyWarning }),
  ev('external_agent_event', { task_id: 't1', kind: 'content', text: 'external content' }),
  ev('external_agent_event', { task_id: 't1', kind: 'warning' }),
], { ahora: BASE + 5000 });
assert('SNAP dependency warning visible once as public progress', dependencyActivity.progreso.length === 1 && dependencyActivity.progreso[0] === dependencyWarning);
assert('SNAP dependency warning classified', dependencyActivity.desconocidos.length === 0);

// ── el respaldo declara quién falló, por qué y quién siguió ──
// Orden #890 real: `agent:claude-code` fijado salió con código 1 y la tarea la
// terminó Cohere en silencio. La tarjeta de respaldo no puede quedarse en un
// genérico que oculte al ejecutor fijado que falló.
seq = 0;
const fallback = construirActividad(
  [
    ev('task_started', { task_id: 't1', department: 'programacion', description: 'calculadora', provider: 'agent:claude-code', model: 'claude-code' }, BASE + 1000),
    ev('provider_fallback', {
      task_id: 't1',
      from_provider: 'agent:claude-code', from_model: 'claude-code',
      reason: 'código de salida 1: login required',
      to_provider: 'Cohere', to_model: 'command-a',
    }, BASE + 3000),
    ev('task_done', { task_id: 't1', success: true, model_used: 'command-a' }, BASE + 4000),
    ev('order_done', { completed: 1, failed: 0 }, BASE + 5000),
  ],
  MUERTO
);
const opFallback = fallback.operaciones.find((o) => o.id === 'proveedor:fallback');
assert('el respaldo es una operación visible', !!opFallback, JSON.stringify(fallback.operaciones.map((o) => o.id)));
assert('el respaldo dice quién falló', !!opFallback && opFallback.detalle.includes('agent:claude-code · claude-code'), opFallback && opFallback.detalle);
assert('el respaldo dice el motivo real', !!opFallback && opFallback.detalle.includes('código de salida 1: login required'), opFallback && opFallback.detalle);
assert('el respaldo dice quién siguió', !!opFallback && opFallback.detalle.includes('siguió Cohere · command-a'), opFallback && opFallback.detalle);
assert('el respaldo se marca como bloqueo, no como éxito', !!opFallback && opFallback.estado === 'bloqueado', opFallback && opFallback.estado);

// Payload antiguo de live_worker (sin from_*/reason): la tarjeta no se rompe.
seq = 0;
const fallbackLegado = construirActividad(
  [ev('provider_fallback', { to_provider: 'OpenCode', to_model: 'deepseek-v4-flash', status: 'empty' }), ev('order_done', {})],
  MUERTO
);
const opLegado = fallbackLegado.operaciones.find((o) => o.id === 'proveedor:fallback');
assert('un respaldo sin origen declara el genérico, no un hueco', !!opLegado && opLegado.detalle.includes('El proveedor no respondió'), opLegado && opLegado.detalle);
assert('un respaldo sin motivo usa el status real', !!opLegado && opLegado.detalle.includes('empty'), opLegado && opLegado.detalle);
assert('un respaldo legado conserva el destino', !!opLegado && opLegado.detalle.includes('siguió OpenCode · deepseek-v4-flash'), opLegado && opLegado.detalle);

// ── USUARIO-NUEVO B (10-nov): modo «DevAgents», subtareas delegadas ───────
seq = 0;
const delegada = construirActividad(
  [
    ev('directo_started_v1', { provider: 'OpenRouter', model: 'x:free', tools: true, delegate: true }, BASE),
    ev('delegation_started_v1', { count: 3, subtasks: [
      { index: 1, role: 'Programación', instruction: 'crea api.js', child_order_id: 41, model: null, setup_error: null },
      { index: 2, role: 'Documentación', instruction: 'escribe GUIA.md', child_order_id: 42, model: 'm-doc', setup_error: null },
      { index: 3, role: 'Pruebas', instruction: 'prueba api', child_order_id: 0, model: null, setup_error: 'no se pudo preparar el worktree de la subtarea' },
    ] }, BASE + 1000),
    ev('delegation_subtask_finished_v1', { index: 1, role: 'Programación', child_order_id: 41, status: 'done', verdict: 'PASS', model: 'm-prog', duration_ms: 42000, files: ['api.js'], integrated: true, conflict: false, note: 'integrada en la carpeta del proyecto', error: null }, BASE + 43000),
    ev('delegation_subtask_finished_v1', { index: 2, role: 'Documentación', child_order_id: 42, status: 'failed', verdict: 'sin auditar', model: 'm-doc', duration_ms: 9000, files: [], integrated: false, conflict: false, note: 'falló: no se integró', error: 'el modelo no produjo el archivo' }, BASE + 44000),
    ev('delegation_subtask_finished_v1', { index: 3, role: 'Pruebas', child_order_id: 0, status: 'failed', verdict: 'sin auditar', model: '', duration_ms: 0, files: [], integrated: false, conflict: false, note: 'falló: no se integró', error: 'no se pudo preparar el worktree de la subtarea' }, BASE + 44000),
    ev('native_tool_result_v1', { tool_name: 'delegate_tasks', task_id: 'directo', ok: true, integrated: 1 }, BASE + 44500),
    ev('delegation_finished_v1', { cancelled: false, integrated: 1, count: 3 }, BASE + 44600),
    ev('order_done', {}, BASE + 50000),
  ],
  MUERTO
);
const subs = delegada.operaciones.filter((o) => o.familia === 'subagente');
assert('una línea por subtarea, en la familia subagente', subs.length === 3, JSON.stringify(delegada.operaciones.map((o) => o.id)));
assert('el resultado de delegate_tasks no se pinta otra vez como herramienta', !delegada.operaciones.some((o) => o.titulo.includes('delegate_tasks')));
assert('la línea dice rol, estado y duración', subs[0].titulo === 'Subtarea 1 · Programación · hecha · 42 s', subs[0].titulo);
assert('la línea dice el modelo que la hizo', subs[0].atribucion === 'm-prog', subs[0].atribucion);
assert('la línea despliega a su orden hija', subs[0].ordenHija === 41 && subs[1].ordenHija === 42, `${subs[0].ordenHija} ${subs[1].ordenHija}`);
assert('una subtarea hecha y aprobada es ok', subs[0].estado === 'ok');
assert('una subtarea fallida es fallo con su motivo', subs[1].estado === 'fallo' && subs[1].detalle.includes('el modelo no produjo el archivo'), subs[1].detalle);
assert('la instrucción se conserva en el detalle', subs[1].detalle.startsWith('escribe GUIA.md'), subs[1].detalle);
assert('una subtarea sin orden hija no se despliega', subs[2].ordenHija === undefined);
assert('el grupo dice que delegó', resumenActividad(delegada).includes('Delegó en 3 subagentes') || delegada.grupos.some((g) => g.etiqueta === 'Delegó en 3 subagentes'), JSON.stringify(delegada.grupos));
assert('el progreso cuenta lo integrado', delegada.progreso.some((t) => t === 'Delegación terminada: 1 de 3 subtarea(s) integradas en la carpeta del proyecto.'), JSON.stringify(delegada.progreso));
seq = 0;
const sinGit = construirActividad(
  [
    ev('delegation_blocked_v1', { cause: 'no_git' }, BASE),
    ev('native_tool_result_v1', { tool_name: 'delegate_tasks', task_id: 'directo', error: 'no_git', detail: 'No se delegó: …' }, BASE + 10),
    ev('order_done', {}, BASE + 20),
  ],
  MUERTO
);
assert('sin git: un bloqueo que ofrece «Iniciar git aquí»', sinGit.bloqueos.some((b) => b.accion.includes('Iniciar git aquí')), JSON.stringify(sinGit.bloqueos));
assert('sin git: no se repite como tarjeta de herramienta', !sinGit.operaciones.some((o) => o.familia === 'subagente'), JSON.stringify(sinGit.operaciones));
seq = 0;
const limite = construirActividad(
  [ev('native_tool_result_v1', { tool_name: 'delegate_tasks', task_id: 'directo', error: 'too_many_subtasks', detail: 'Como máximo se delegan 4 subtareas por llamada.' }, BASE), ev('order_done', {}, BASE + 5)],
  MUERTO
);
const opLimite = limite.operaciones.find((o) => o.familia === 'subagente');
assert('un límite de delegación se dice en llano, sin el código', !!opLimite && opLimite.titulo === 'No se delegó' && opLimite.detalle.includes('4 subtareas') && !opLimite.titulo.includes('too_many'), opLimite && JSON.stringify(opLimite));
seq = 0;
const detenida = construirActividad(
  [
    ev('delegation_started_v1', { count: 1, subtasks: [{ index: 1, role: 'Programación', instruction: 'x', child_order_id: 7, model: null, setup_error: null }] }, BASE),
    ev('delegation_subtask_finished_v1', { index: 1, role: 'Programación', child_order_id: 7, status: 'cancelled', verdict: 'sin auditar', model: '', duration_ms: 1500, files: [], integrated: false, note: 'cancelada: no se integró' }, BASE + 1500),
    ev('delegation_finished_v1', { cancelled: true, integrated: 0, count: 1 }, BASE + 1600),
    ev('order_done', {}, BASE + 2000),
  ],
  MUERTO
);
const opDet = detenida.operaciones.find((o) => o.familia === 'subagente');
assert('una subtarea detenida queda sin ejecutar, no fallida ni ok', !!opDet && opDet.estado === 'sin_ejecutar' && opDet.titulo.includes('cancelada'), opDet && JSON.stringify(opDet));
assert('«Detener» se dice en el progreso', detenida.progreso.some((t) => t.startsWith('Delegación detenida')), JSON.stringify(detenida.progreso));

// Remate D4 (10-nov): un rechazo de run_command (B-11) salía tres veces: el
// bloqueo de arriba, el mismo bloqueo «ya visible arriba» y la operación. Se
// cuenta UNA vez, en su operación, con contador si se repitió.
seq = 0;
const detalleR2 = 'No se ejecutó «dir»: es una orden interna de cmd.exe, no un programa.';
const r2 = construirActividad(
  [
    ev('directo_started_v1', { provider: 'Cohere', model: 'command-a-03-2025' }, BASE),
    ev('native_tool_result_v1', { tool_name: 'run_command', task_id: 'directo', error: 'ExeNotAllowed', detail: detalleR2 }, BASE + 10),
    ev('native_tool_result_v1', { tool_name: 'run_command', task_id: 'directo', error: 'ExeNotAllowed', detail: detalleR2 }, BASE + 20),
    ev('native_tool_result_v1', { tool_name: 'run_command', task_id: 'directo', error: 'ExeNotAllowed', detail: detalleR2 }, BASE + 30),
    ev('directo_finished_v1', { ok: true }, BASE + 40),
    ev('order_done', {}, BASE + 50),
  ],
  MUERTO
);
const apariciones =
  r2.operaciones.filter((o) => o.detalle.includes('orden interna')).length +
  bloqueosVigentes(r2).filter((b) => b.detalle.includes('orden interna')).length +
  r2.bloqueos.filter((b) => b.detalle.includes('orden interna')).length;
assert('D4: el rechazo de run_command aparece una sola vez', apariciones === 1, `${apariciones} · ${JSON.stringify(r2.operaciones)} · ${JSON.stringify(r2.bloqueos)}`);
const opR2 = r2.operaciones.find((o) => o.detalle.includes('orden interna'));
assert('D4: con contador porque se repitió', !!opR2 && opR2.titulo === 'No se pudo usar run_command (3 veces)' && opR2.estado === 'fallo', opR2 && JSON.stringify(opR2));
assert('D4: sin el código del motor en el título', !!opR2 && !opR2.titulo.includes('ExeNotAllowed'));

console.log(failed === 0 ? '\nTODO MENOS: TEST PASÓ' : `\n${failed} FALLOS`);
process.exit(failed === 0 ? 0 : 1);
