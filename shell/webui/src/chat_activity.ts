/**
 * chat_activity.ts — divulgación progresiva del turno agéntico (CHAT-PD-1).
 *
 * ## Qué resuelve
 *
 * La conversación mostraba el mecanismo y escondía el resultado: una tarjeta
 * por fragmento de streaming, el mismo fallo repetido como evento, como
 * mensaje técnico, como tarjeta y otra vez dentro de la respuesta, y el
 * «terminó de emitir» tratado como «salió bien».
 *
 * Aquí se separan, DESDE LOS EVENTOS y no con CSS, los seis canales que el
 * usuario necesita distinguir:
 *
 *   1. lo que él escribió,            → `Canal.usuario`
 *   2. avances públicos legibles,     → `Canal.progreso`
 *   3. operaciones y sus resultados,  → `Canal.operacion`
 *   4. diagnóstico técnico,           → `Canal.diagnostico`
 *   5. resúmenes de razonamiento,     → `Canal.razonamiento`
 *   6. la respuesta final.            → `Canal.respuesta`
 *
 * ## Tres reglas que no son de presentación
 *
 * - **Una operación, una tarjeta.** Cada evento se correlaciona con una clave
 *   estable (tarea, comando, archivo, herramienta) y ACTUALIZA la operación
 *   existente. El streaming ya no multiplica tarjetas.
 * - **El éxito no se infiere.** El estado terminal sale de un evento terminal
 *   real (`order_done` / `order_failed` / `order_cancelled`). Si el turno dejó
 *   de emitir sin ninguno, el estado es `interrumpido`, nunca `completado`.
 * - **Lo que no se sabe clasificar no se oculta.** Un `kind` desconocido —de
 *   una versión anterior o futura del motor— cae en `desconocidos` y se
 *   muestra. Esconder lo dudoso es cómo se pierde historial al plegar.
 *
 * La clasificación es por `kind` y por campos estructurados del payload. No se
 * usan expresiones regulares sobre texto libre para decidir de qué canal es un
 * evento: eso es adivinar, y adivina distinto en cada versión del motor.
 *
 * Sin DOM a propósito, como `ui_diag.ts`: estas reglas se prueban solas.
 */
import { OrderEvent, eventPayload } from './bridge/core_api';

/** Los seis canales que la conversación tiene que mantener separados. */
export type Canal =
  | 'usuario'
  | 'progreso'
  | 'operacion'
  | 'diagnostico'
  | 'razonamiento'
  | 'respuesta'
  | 'desconocido';

/** Estado de un turno. `interrumpido` no es `fallido`: nadie decidió nada. */
export type EstadoTurno =
  | 'ejecutando'
  | 'completado'
  | 'fallido'
  | 'cancelado'
  | 'interrumpido'
  // AUDIT-UNAVAILABLE-P0: ejecución conservada pero el auditor no entregó
  // veredicto usable. No es completado (sin auditar) ni fallido (no es un
  // defecto del entregable) ni interrumpido (cerró a propósito).
  | 'sin_auditar'
  | 'esperando';

/** Estado de UNA operación. `sin_ejecutar` no es `ok` ni `fallo`. */
export type EstadoOperacion = 'ejecutando' | 'ok' | 'fallo' | 'sin_ejecutar' | 'bloqueado';

/** Familia de operación. Determina el resumen agrupado y el icono. */
export type Familia =
  | 'tarea'
  | 'auditoria'
  | 'comando'
  | 'archivo'
  | 'lectura'
  | 'proceso'
  | 'prueba'
  | 'navegador'
  | 'herramienta'
  | 'busqueda'
  | 'proveedor'
  | 'subagente'
  | 'otro';

export interface Operacion {
  /** Clave de correlación estable. El streaming actualiza, no duplica. */
  id: string;
  familia: Familia;
  titulo: string;
  detalle: string;
  estado: EstadoOperacion;
  /** Instantes reales, tomados de los eventos. */
  inicio: number;
  fin: number;
  /** Cuántos eventos crudos se plegaron aquí. Sirve para auditar el plegado. */
  eventos: number;
  exitCode?: number;
  process?: { id: string; generation: number; stopped: boolean };
  stdout?: string;
  stderr?: string;
  /**
   * Quién lo hizo DE VERDAD. `Ejecutor local` y `Sin ejecutar` no se atribuyen
   * a ningún proveedor: no los hizo un modelo.
   */
  atribucion: string;
  /** Id de tarea del motor, cuando el evento lo trae. */
  taskId: string;
  /**
   * USUARIO-NUEVO B: orden hija de una subtarea delegada. La cabina la
   * despliega pidiendo los eventos de esa orden (sus operaciones reales).
   */
  ordenHija?: number;
}

export interface Bloqueo {
  titulo: string;
  detalle: string;
  /** Qué puede hacer el usuario. Vacío si no hay acción disponible. */
  accion: string;
  /** Un fallo del que el turno se recuperó después. Se conserva, marcado. */
  resuelto: boolean;
  /** Ámbito de deduplicado (task_id). Evita colapsar fallos de tareas distintas. */
  ambito?: string;
  /**
   * 22-09: fallo intermedio del que el motor sabe recuperarse (un proveedor
   * agotado con respaldo, una sesión de herramientas que se reintenta). Si la
   * orden termina completada, queda resuelto: la cabina decía a la vez
   * «Completado» y «Ningún proveedor respondió» en rojo.
   */
  recuperable?: boolean;
}

export interface PendienteDeUsuario {
  tipo: 'aprobacion' | 'pregunta';
  titulo: string;
  detalle: string;
  /** Solicitud del motor que la cabina puede resolver desde el hilo. */
  approvalId?: number;
}

export interface Razonamiento {
  texto: string;
  /** De dónde salió. Nunca se rellena con una narración posterior. */
  procedencia: string;
}

export interface ResumenGrupo {
  familia: Familia;
  etiqueta: string;
  cantidad: number;
}

export interface ActividadTurno {
  estado: EstadoTurno;
  inicio: number;
  fin: number;
  transcurridoMs: number;
  operaciones: Operacion[];
  grupos: ResumenGrupo[];
  /** Avances públicos, breves, en orden. */
  progreso: string[];
  bloqueos: Bloqueo[];
  pendientes: PendienteDeUsuario[];
  razonamiento: Razonamiento | null;
  /** Eventos cuya clasificación es incierta. Se muestran, no se esconden. */
  desconocidos: Array<{ kind: string; texto: string }>;
  /** Número de acciones reales (operaciones), no de eventos crudos. */
  acciones: number;
  /** Total de eventos considerados. Para el enlace al registro completo. */
  eventos: number;
}

/**
 * Tabla de canales por `kind`. Es la única fuente de la clasificación.
 *
 * Lo que NO está aquí es deliberadamente `desconocido`: se muestra tal cual en
 * lugar de caer en una heurística que lo mande al canal equivocado.
 */
const CANAL_POR_KIND: Record<string, Canal> = {
  // Progreso público
  superagent_thinking: 'progreso',
  order_running: 'progreso',
  order_resumed: 'progreso',
  plan_edited: 'progreso',
  auto_verify_triggered: 'progreso',
  agent_iteration: 'progreso',
  iteration_completed: 'progreso',
  // Operaciones
  task_started: 'operacion',
  task_done: 'operacion',
  task_failed: 'operacion',
  // una tarea que falló por artefacto inválido y se re-despacha con
  // otro candidato. Es una operación de la tarea, no un fallo terminal.
  task_retry: 'operacion',
  task_audit: 'operacion',
  task_audit_unavailable_v1: 'operacion',
  shell_command: 'operacion',
  file_written: 'operacion',
  process_launched: 'operacion',
  test_evidence_v1: 'operacion',
  browser_gate_v1: 'operacion',
  native_tool_result_v1: 'operacion',
  // D-C1 (E5.11): degradación honesta del modo agéntico.
  agentic_unavailable: 'operacion',
  web_search: 'operacion',
  web_search_failed: 'operacion',
  exec_skipped: 'operacion',
  subagent_stream_start: 'operacion',
  subagent_stream_end: 'operacion',
  open_design_run_started: 'operacion',
  previewAvailable: 'operacion',
  // Diagnóstico técnico
  subscription_call_v1: 'diagnostico',
  provider_failed: 'diagnostico',
  provider_fallback: 'diagnostico',
  provider_exhausted: 'diagnostico',
  provider_contract_abort: 'diagnostico',
  task_provider_ok: 'diagnostico',
  task_provider_failed: 'diagnostico',
  planner_fallback: 'diagnostico',
  // QA-B H7: qué CLI con suscripción planificó (sin clave de API).
  planner_cli_v1: 'operacion',
  cli_account_rotated_v1: 'operacion',
  local_json_retry: 'diagnostico',
  local_json_fallback: 'diagnostico',
  local_json_failed: 'diagnostico',
  dispatch_failed: 'diagnostico',
  governance_blocked_v1: 'diagnostico',
  budget_blocked_v1: 'diagnostico',
  approval_needed: 'operacion',
  approval_required: 'operacion',
  approval_resolved: 'operacion',
  approval_closed: 'operacion',
  native_tool_session_failed_v1: 'diagnostico',
  native_tool_session_stopped_v1: 'diagnostico',
  artifact_incoherent: 'diagnostico',
  design_degraded: 'diagnostico',
  open_design_submit_failed: 'diagnostico',
  semantic_gate_v1: 'diagnostico',
  // 22-09: auditoría impuesta por el motor y citas comprobadas.
  plan_audit_enforced_v1: 'operacion',
  audit_citations_v1: 'operacion',
  // E5.04/E5.05: preparación del worktree — el resultado de la
  // preparación por orden es una operación visible de la orden.
  worktree_prepare_started: 'operacion',
  worktree_prepared: 'operacion',
  worktree_setup_failed: 'operacion',
  worktree_setup_suggested: 'operacion',
  rate_limit_retry: 'diagnostico',
  clarify_exhausted: 'diagnostico',
  // USUARIO-NUEVO B (10-nov): modo «DevAgents». Cada subtarea delegada es UNA
  // operación (familia `subagente`) dentro del grupo plegable de la vuelta.
  delegation_started_v1: 'operacion',
  delegation_subtask_finished_v1: 'operacion',
  delegation_finished_v1: 'progreso',
  delegation_blocked_v1: 'diagnostico',
  ship_started: 'operacion',
  ship_done: 'operacion',
  ship_failed: 'operacion',
  content_delta: 'diagnostico',
  // La corriente cruda del worker es diagnóstico: su contenido ya llega a la
  // conversación por el resultado del comando y por la evidencia de pruebas.
  // Repetirlo aquí sería el mismo fallo contado cuatro veces.
  worker_output: 'diagnostico',
  external_agent_event: 'diagnostico',
  subagent_stream_chunk: 'diagnostico',
  cross_turn_event: 'diagnostico',
  // Razonamiento (sólo si el proveedor lo entrega)
  reasoning_delta: 'razonamiento',
  // Respuesta final y estados terminales
  agent_message: 'respuesta',
  order_done: 'respuesta',
  order_failed: 'respuesta',
  order_cancelled: 'respuesta',
  order_audit_unavailable_v1: 'respuesta',
};

export function canalDe(kind: string): Canal {
  return CANAL_POR_KIND[kind] ?? 'desconocido';
}

/** Etiquetas de grupo, en plural y singular. Nada se inventa: cuenta lo que hay. */
const ETIQUETA_GRUPO: Record<Familia, [string, string]> = {
  tarea: ['Ejecutó 1 tarea', 'Ejecutó {n} tareas'],
  auditoria: ['Auditó 1 tarea', 'Auditó {n} tareas'],
  comando: ['Ejecutó 1 comando', 'Ejecutó {n} comandos'],
  archivo: ['Escribió 1 archivo', 'Escribió {n} archivos'],
  lectura: ['Leyó 1 archivo', 'Leyó {n} archivos'],
  proceso: ['Lanzó 1 proceso', 'Lanzó {n} procesos'],
  prueba: ['Verificó las pruebas', 'Verificó las pruebas ({n} veces)'],
  navegador: ['Comprobó la página en un navegador', 'Comprobó la página en un navegador ({n} veces)'],
  herramienta: ['Usó 1 herramienta', 'Usó {n} herramientas'],
  busqueda: ['Buscó en la web', 'Buscó en la web ({n} veces)'],
  proveedor: ['Probó 1 proveedor', 'Probó {n} proveedores'],
  subagente: ['Delegó en 1 subagente', 'Delegó en {n} subagentes'],
  otro: ['1 acción', '{n} acciones'],
};

/** USUARIO-NUEVO B: estado de una subtarea delegada (status de su orden hija). */
const ESTADO_SUBTAREA: Record<string, string> = {
  done: 'hecha',
  failed: 'falló',
  cancelled: 'cancelada',
  audit_unavailable: 'sin auditar',
  running: 'en curso',
};

/**
 * Causas que significan «falló porque falló otra cosa». Vienen del campo
 * estructurado `cause` del motor, no de leer el mensaje de error.
 */
const CAUSAS_DE_ARRASTRE = new Set(['dependency_failed', 'upstream_failed', 'cancelled']);

/** Nombres de herramienta que son LECTURA. Campo estructurado, no texto libre. */
const HERRAMIENTAS_DE_LECTURA = new Set(['read', 'read_file', 'cat', 'view', 'open_file', 'get_file']);

/**
 * Marca de tiempo del evento, en milisegundos de época, o 0 si no la hay.
 *
 * No todo evento persistido trae una: en la traza real de la orden 437 los
 * cinco primeros llegan con `ts` 1..5, que no es un instante sino un relleno
 * del exportador. Tomarlos como el arranque del turno daba «trabajó durante
 * 56.000 años». Un valor que no puede ser una fecha no se usa para medir; se
 * ignora y el turno empieza a contar en el primer evento que sí la trae.
 */
const EPOCA_MINIMA = 1_000_000_000_000;

function marcaDeTiempo(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) && n >= EPOCA_MINIMA ? n : 0;
}

function texto(v: unknown): string {
  return v === undefined || v === null ? '' : String(v);
}

/**
 * Rango 0x80–0xFF de cp850 (OEM, la página de la consola Windows es-ES)
 * según la tabla IBM oficial. `TextDecoder` no soporta cp850 — el Encoding
 * Standard solo lista ibm866 — así que el mapeo va a mano.
 */
const CP850_ALTA =
  'ÇüéâäàåçêëèïîìÄÅ' +
  'ÉæÆôöòûùÿÖÜø£Ø×ƒ' +
  'áíóúñÑªº¿®¬½¼¡«»' +
  '░▒▓│┤ÁÂÀ©╣║╗╝¢¥' +
  '┐└┴┬├─┼ãÃ╚╔╩╦╠' +
  '═╬¤ðÐÊËÈıÍÎÏ┘┌' +
  '█▄¦Ì▀ÓßÔÒõÕµþÞ' +
  'ÚÛÙýÝ¯´­±‗¾¶§÷' +
  '¸°¨·¹³²■ ';

function decodificaCp850(bytes: Uint8Array): string {
  let out = '';
  for (const b of bytes) out += b < 0x80 ? String.fromCharCode(b) : CP850_ALTA[b - 0x80];
  return out;
}

/**
 * La persistencia de eventos guarda el texto no-UTF8 de la consola Windows
 * como array de bytes — `[92,116,…]` — en vez de string. Mostrarlo tal
 * cual imprime la ensalada de números; se decodifica aquí.
 * La consola es-ES emite OEM cp850: con el fallback anterior a
 * windows-1252, «está» salía «est  da¤ado» (E2.7). Un payload que fuera
 * realmente cp1252 (app gráfica, no consola) degrada sus comillas
 * tipográficas a vocales acentuadas — legible, no la ensalada de números
 * que esta función existe para evitar.
 */
export function textoDeBytes(v: unknown): string {
  if (!Array.isArray(v)) return texto(v);
  const bytes = Uint8Array.from(v.filter((b): b is number => typeof b === 'number'));
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    return decodificaCp850(bytes);
  }
}

function numero(v: unknown): number | undefined {
  const n = Number(v);
  return Number.isFinite(n) ? n : undefined;
}

/**
 * Atribución honesta de quién hizo una operación.
 *
 * Un comando lo corre el motor en la máquina del usuario: no tiene proveedor y
 * decir que lo hizo un modelo sería falso. Una operación que no llegó a correr
 * tampoco se le cuelga a nadie.
 */
function atribucionDe(p: Record<string, unknown>, ejecutada: boolean, local: boolean): string {
  if (!ejecutada) return 'Sin ejecutar';
  if (local) return 'Ejecutor local';
  const proveedor = texto(p.provider);
  const modelo = texto(p.model ?? p.model_used ?? p.assigned_model);
  const partes = [proveedor, modelo].filter(Boolean);
  return partes.length ? partes.join(' · ') : 'Proveedor no declarado';
}

interface Acumulador {
  ops: Map<string, Operacion>;
  orden: string[];
}

function tocar(
  acc: Acumulador,
  id: string,
  familia: Familia,
  ts: number,
  parche: Partial<Operacion>
): Operacion {
  let op = acc.ops.get(id);
  if (!op) {
    op = {
      id,
      familia,
      titulo: '',
      detalle: '',
      estado: 'ejecutando',
      inicio: ts,
      fin: ts,
      eventos: 0,
      atribucion: 'Sin ejecutar',
      taskId: '',
    };
    acc.ops.set(id, op);
    acc.orden.push(id);
  }
  op.eventos += 1;
  op.fin = ts;
  // Un parche nunca borra lo que ya había: el streaming llega por trozos y el
  // último trozo no tiene por qué repetir el título ni el comando.
  for (const [k, v] of Object.entries(parche)) {
    if (v === undefined || v === '') continue;
    (op as unknown as Record<string, unknown>)[k] = v;
  }
  return op;
}

export interface OpcionesActividad {
  /** Reloj para calcular el transcurrido de un turno vivo. */
  ahora: number;
  /**
   * `true` mientras el turno sigue emitiendo. En `false`, un turno sin evento
   * terminal se declara INTERRUMPIDO en lugar de darse por bueno.
   */
  vivo: boolean;
}

/**
 * Construye la actividad de UN turno a partir de sus eventos.
 *
 * Es pura y determinista: los mismos eventos producen la misma agrupación al
 * reabrir la conversación, que es lo que hace que el plegado no pierda nada.
 */
export function construirActividad(events: OrderEvent[], opciones: OpcionesActividad): ActividadTurno {
  const acc: Acumulador = { ops: new Map(), orden: [] };
  const progreso: string[] = [];
  const bloqueos: Bloqueo[] = [];
  // Remate D4 (10-nov): veces que se rechazó cada herramienta (por operación).
  const rechazos = new Map<string, number>();
  const pendientes: PendienteDeUsuario[] = [];
  const desconocidos: ActividadTurno['desconocidos'] = [];
  const razonamientoTrozos: string[] = [];
  let razonamientoProcedencia = '';
  let estado: EstadoTurno = events.length ? 'ejecutando' : 'ejecutando';
  let inicio = 0;
  let fin = 0;

  const anotarBloqueo = (titulo: string, detalle: string, accion: string, ambito = '', recuperable = false): void => {
    // Deduplicado por firma: el mismo fallo llega como evento, como resultado
    // de la tarea y como causa de la orden. Es UN bloqueo, no tres.
    // El ambito (task_id) separa comandos DISTINTOS con el mismo destino y el
    // mismo error (hallazgo H-3 de la auditoria de cabina del 09-09): dentro
    // de una tarea el deduplicado sigue valiendo.
    const firma = `${ambito}\u0000${titulo}\u0000${detalle}`;
    for (const b of bloqueos) {
      if (`${b.ambito ?? ''}\u0000${b.titulo}\u0000${b.detalle}` === firma) return;
    }
    bloqueos.push({ titulo, detalle, accion, resuelto: false, ambito, recuperable });
  };

  const resolverBloqueosDe = (taskId: string): void => {
    if (!taskId) return;
    for (const b of bloqueos) {
      if (b.detalle.includes(taskId) || b.titulo.includes(taskId)) b.resuelto = true;
    }
  };

  // QA primerizo (10-nov): en Directo la respuesta del chat YA explica el
  // fallo en español («Directo: el modelo no respondió…»). Las tarjetas de
  // «Ningún proveedor respondió» (con el detalle técnico en inglés) y «La
  // orden terminó con errores» repetían lo mismo hasta cuatro veces.
  const esDirecto = events.some((ev) => texto(ev.kind) === 'directo_started_v1');

  for (const e of events) {
    const kind = texto(e.kind);
    const p = eventPayload(e);
    const ts = marcaDeTiempo(e.ts);
    if (ts) {
      if (!inicio) inicio = ts;
      fin = ts;
    }
    const canal = canalDe(kind);

    if (canal === 'desconocido') {
      desconocidos.push({ kind, texto: JSON.stringify(p).slice(0, 400) });
      continue;
    }

    switch (kind) {
      case 'external_agent_event': {
        // Warnings emitted by the external worker include the snapshot's
        // dependency metadata comparison; render as escaped public progress.
        const t = texto(p.text).trim();
        if (p.kind === 'warning' && t && progreso[progreso.length - 1] !== t) progreso.push(t);
        // (9-nov): en Directo con un agente externo no hay tareas ni
        // consolas de worker; sus herramientas y su plan son el único progreso
        // visible mientras trabaja (si no, parecía colgado).
        else if (p.task_id === 'directo' && (p.kind === 'tool' || p.kind === 'plan' || p.kind === 'status') && t) {
          const linea = t.split(/\r?\n/)[0].slice(0, 160);
          if (progreso[progreso.length - 1] !== linea) progreso.push(linea);
        }
        break;
      }
      case 'superagent_thinking': {
        const t = texto(p.text).trim();
        if (t && progreso[progreso.length - 1] !== t) progreso.push(t);
        break;
      }
      case 'order_running':
        if (progreso.length === 0) progreso.push('La orden empezó a ejecutarse.');
        break;
      case 'order_resumed':
        progreso.push('La orden se reanudó.');
        break;
      case 'plan_edited':
        progreso.push('El plan fue editado.');
        break;
      case 'auto_verify_triggered':
        progreso.push('Verificación automática en curso.');
        break;
      case 'agent_iteration':
      case 'iteration_completed': {
        const t = texto(p.text ?? p.summary).trim();
        if (t && progreso[progreso.length - 1] !== t) progreso.push(t);
        break;
      }

      case 'task_started': {
        const id = texto(p.task_id);
        const op = tocar(acc, `tarea:${id}`, 'tarea', ts, {
          titulo: `Tarea ${id}${p.department ? ` · ${texto(p.department)}` : ''}`,
          detalle: texto(p.description),
          taskId: id,
          estado: 'ejecutando',
        });
        op.atribucion = atribucionDe(p, true, false);
        break;
      }
      case 'task_done':
      case 'task_failed': {
        const id = texto(p.task_id);
        const ok = p.success === true;
        const op = tocar(acc, `tarea:${id}`, 'tarea', ts, {
          taskId: id,
          estado: ok ? 'ok' : 'fallo',
          detalle: ok ? undefined : texto(p.error_msg ?? p.cause),
        });
        if (!op.titulo) op.titulo = `Tarea ${id}`;
        if (texto(p.model_used)) op.atribucion = atribucionDe({ model: p.model_used, provider: p.provider }, true, false);
        if (ok) resolverBloqueosDe(id);
        else if (!CAUSAS_DE_ARRASTRE.has(texto(p.cause))) {
          // Una tarea que falla PORQUE su dependencia falló es la consecuencia,
          // no el bloqueo. En la orden 437 tres tareas fallaron por arrastre y
          // la conversación acababa con diez tarjetas rojas contando el mismo
          // problema. La operación sigue marcada como fallida dentro de la
          // actividad; lo que no hace es reclamar atención por su cuenta.
          anotarBloqueo(
            `Tarea ${id} fallida`,
            [CAUSA_FALLO_TAREA[texto(p.cause)] ?? texto(p.cause), texto(p.error_msg)].filter(Boolean).join(' — '),
            'Revisa el detalle y reintenta la orden.'
          );
        }
        break;
      }
      case 'task_retry': {
        // fallo de artefacto (Excel: InvalidArtifact, JSON ilegible,
        // contrato vacío) que el motor re-despacha con otro candidato. El motivo
        // y el modelo que falló vienen estructurados en el payload; se muestran
        // en la conversación, no solo en la traza completa.
        const id = texto(p.task_id);
        const motivo = texto(p.reason) || 'artefacto inválido';
        const fallo = texto(p.failed_model ?? p.assigned_model);
        const reintento = [texto(p.retry_provider), texto(p.retry_model)].filter(Boolean).join(' · ');
        tocar(acc, `tarea:${id}`, 'tarea', ts, {
          titulo: `Reintento de ${id}`,
          detalle: [`Reintento: ${motivo}`, fallo ? `falló ${fallo}` : '', reintento ? `siguiente: ${reintento}` : '']
            .filter(Boolean)
            .join(' — '),
          taskId: id,
          estado: 'ejecutando',
          atribucion: reintento || undefined,
        });
        progreso.push(`Reintento de ${id}: ${motivo}${fallo ? ` (falló ${fallo})` : ''}`);
        break;
      }
      case 'task_audit': {
        const id = texto(p.task_id);
        const veredicto = texto(p.verdict).toUpperCase();
        tocar(acc, `auditoria:${id}`, 'auditoria', ts, {
          titulo: `Auditoría de ${id}: ${veredicto || 'sin veredicto'}`,
          detalle: texto(p.notes),
          taskId: id,
          estado: veredicto === 'PASS' ? 'ok' : veredicto === 'FAIL' ? 'fallo' : 'bloqueado',
          atribucion: atribucionDe(p, true, false),
        });
        if (veredicto === 'FAIL') {
          anotarBloqueo(`La auditoría rechazó ${id}`, texto(p.notes), 'Corrige el productor o reintenta.');
        }
        break;
      }
      case 'task_audit_unavailable_v1': {
        // El auditor no entregó veredicto usable: ni PASS ni FAIL del producto.
        // Se conserva como operación bloqueada, no como fallo ni como ok.
        const id = texto(p.task_id);
        tocar(acc, `auditoria:${id}`, 'auditoria', ts, {
          titulo: `Auditoría de ${id}: sin veredicto`,
          detalle: 'El proveedor de auditoría no devolvió un veredicto usable; la ejecución se conserva.',
          taskId: id,
          estado: 'bloqueado',
          atribucion: atribucionDe(p, true, false),
        });
        break;
      }

      // E5.04/E5.05: la preparación del worktree de la orden. Los
      // cuatro eventos comparten la operación `worktree:prepare` — started la
      // abre, prepared/failed la cierran y suggested informa cuando no hay
      // `.devagents/worktree.json` (los comandos sugeridos nunca se ejecutan).
      case 'worktree_prepare_started': {
        tocar(acc, 'worktree:prepare', 'comando', ts, {
          titulo: 'Preparando el worktree de la orden…',
          detalle: texto(p.space),
          estado: 'ejecutando',
          atribucion: 'Ejecutor local',
        });
        break;
      }
      case 'worktree_prepared': {
        const partes: string[] = [];
        if (numero(p.copied) !== undefined) partes.push(`${texto(p.copied)} copiado(s)`);
        if (numero(p.skipped_existing)) partes.push(`${texto(p.skipped_existing)} ya presente(s)`);
        if (numero(p.skipped_missing)) partes.push(`${texto(p.skipped_missing)} ausente(s)`);
        const setup = texto(p.setup);
        partes.push(setup === 'ran' ? 'setup ejecutado' : 'sin setup');
        tocar(acc, 'worktree:prepare', 'comando', ts, {
          titulo: 'Worktree preparado',
          detalle: partes.join(' · '),
          estado: 'ok',
        });
        break;
      }
      case 'worktree_setup_failed': {
        const causa = texto(p.cause);
        const detalle = [
          CAUSA_FALLO_TAREA[causa] ?? causa,
          texto(p.detail),
          texto(p.script) ? `script: ${texto(p.script)}` : '',
          numero(p.exit_code) !== undefined ? `código ${texto(p.exit_code)}` : '',
          p.timed_out === true ? 'agotado por timeout' : '',
        ]
          .filter(Boolean)
          .join(' — ');
        tocar(acc, 'worktree:prepare', 'comando', ts, {
          titulo: 'La preparación del worktree falló',
          detalle,
          estado: 'fallo',
        });
        anotarBloqueo(
          'La preparación del worktree falló',
          detalle,
          causa === 'pending_approval'
            ? 'Aprueba el script de setup en el Monitor para que la próxima orden lo ejecute.'
            : 'Revisa .devagents/worktree.json y reintenta la orden.'
        );
        break;
      }
      case 'worktree_setup_suggested': {
        const comandos = Array.isArray(p.commands)
          ? (p.commands as unknown[]).map((c) => texto(c)).filter(Boolean)
          : [];
        tocar(acc, 'worktree:prepare', 'comando', ts, {
          titulo: 'Worktree sin preparación configurada',
          detalle: comandos.length
            ? `Sin .devagents/worktree.json. El motor sugiere (sin ejecutar): ${comandos.join(', ')}`
            : 'Sin .devagents/worktree.json.',
          estado: 'ok',
        });
        break;
      }

      case 'shell_command': {
        const comando = texto(p.command).trim();
        const archivo = texto(p.file).trim();
        // `command` ya es la línea efectiva completa (exe + argv, con el file
        // dentro como arg si lo hay): el running la trae y los delta la
        // repiten. Sumar `file` otra vez rompía la correlación — el running
        // componía "cmd file" y el delta solo "cmd", y cada chunk abría una
        // card nueva vacía.
        const destino = comando || archivo;
        if (!destino) {
          // Un `shell_command` sin `command` ni `file` no puede desaparecer de
          // la vista (hallazgo H-2 de la auditoría de cabina del 09-09): la
          // regla de la casa es que lo que no se sabe mostrar se MUESTRA.
          desconocidos.push({ kind, texto: JSON.stringify(p).slice(0, 400) });
          break;
        }
        const id = `comando:${texto(p.task_id)}:${destino}`;
        const status = texto(p.status).toLowerCase();
        // `running` y `delta` ACTUALIZAN la misma operación. Antes cada trozo
        // producía una tarjeta nueva y vacía.
        if (status === 'running' || status === 'delta' || status === '') {
          const op = tocar(acc, id, 'comando', ts, {
            // Etiqueta activa mientras corre; el `done` de abajo la cierra con
            // "Ejecutó" — el patrón activeLabel→label del resto del mercado.
            titulo: `Ejecutando ${destino}`,
            taskId: texto(p.task_id),
            estado: 'ejecutando',
            atribucion: 'Ejecutor local',
          });
          // El `delta` lleva el trozo de salida EN VIVO (payload.chunk +
          // stream). Antes se descartaba: la card quedaba vacía hasta el
          // `done`, así que "streaming" solo existía en la traza. Ahora el
          // stdout/stderr crecen mientras el proceso corre, que es lo que se
          // ve en Devin/Claude Code/Cursor.
          const chunk = textoDeBytes(p.chunk);
          if (chunk) {
            if (texto(p.stream) === 'stderr') op.stderr = (op.stderr ?? '') + chunk;
            else op.stdout = (op.stdout ?? '') + chunk;
          }
          break;
        }
        const exit = numero(p.exit_code);
        const agotado = p.timed_out === true;
        const ok = exit === 0 && !agotado;
        const op = tocar(acc, id, 'comando', ts, {
          titulo: `Ejecutó ${destino}`,
          taskId: texto(p.task_id),
          estado: agotado ? 'bloqueado' : ok ? 'ok' : 'fallo',
          atribucion: 'Ejecutor local',
          stdout: textoDeBytes(p.stdout),
          stderr: textoDeBytes(p.stderr),
        });
        op.exitCode = exit;
        op.detalle =
          exit === undefined
            ? 'Código de salida no informado'
            : agotado
              ? `Tiempo agotado (código ${exit})`
              : `Código de salida ${exit}`;
        if (!ok) {
          anotarBloqueo(
            agotado ? `Comando detenido por tiempo: ${destino}` : `Comando falló: ${destino}`,
            [op.detalle, textoDeBytes(p.stderr)].filter(Boolean).join('\n'),
            'Abre el detalle para ver la salida completa.',
            texto(p.task_id)
          );
        }
        break;
      }

      case 'exec_skipped': {
        // El motor reporta el comando rechazado en `command` (línea completa)
        // o en `file` (ruta heredada). Ambos identifican qué NO corrió.
        const objeto = texto(p.command).trim() || texto(p.file);
        const nombre = texto(p.command).trim() ? objeto : basename(objeto);
        tocar(acc, `comando:${texto(p.task_id)}:${objeto}`, 'comando', ts, {
          titulo: `No se ejecutó ${nombre}`,
          detalle: [texto(p.razon), objeto].filter(Boolean).join(' — '),
          taskId: texto(p.task_id),
          estado: 'sin_ejecutar',
          atribucion: 'Sin ejecutar',
        });
        break;
      }

      case 'file_written': {
        const ruta = texto(p.file_path ?? p.artifact_name);
        if (!ruta) break;
        tocar(acc, `archivo:${ruta}`, 'archivo', ts, {
          titulo: `Escribió ${basename(ruta)}`,
          detalle: ruta,
          taskId: texto(p.task_id),
          estado: 'ok',
          atribucion: 'Ejecutor local',
        });
        break;
      }

      case 'process_launched': {
        const archivo = texto(p.file);
        tocar(acc, `proceso:${archivo}:${texto(p.pid)}`, 'proceso', ts, {
          titulo: `Lanzó ${basename(archivo)} (PID ${texto(p.pid) || '?'})`,
          detalle: texto(p.mode) === 'detached' ? 'proceso independiente' : '',
          estado: 'ok',
          atribucion: 'Ejecutor local',
        });
        break;
      }

      case 'test_evidence_v1': {
        const id = texto(p.producer_task_id ?? p.task_id);
        const corrio = p.ran === true;
        const exit = numero(p.exit_code);
        const ok = corrio && exit === 0 && p.timed_out !== true;
        const remate = !corrio
          ? 'sin ejecutar'
          : p.timed_out === true
            ? 'tiempo agotado'
            : ok
              ? 'correctas'
              : `falló (código ${exit === undefined ? 'no informado' : exit})`;
        const op = tocar(acc, `prueba:${id}`, 'prueba', ts, {
          titulo: `Pruebas de ${id}: ${remate}`,
          // La revisión del productor va en el detalle porque es lo que ata la
          // prueba a UNOS bytes concretos: sin ella, «pasó» no dice de qué.
          detalle: [texto(p.command), texto(p.producer_revision) ? `Revisión ${texto(p.producer_revision)}` : '']
            .filter(Boolean)
            .join(' · '),
          taskId: id,
          estado: !corrio ? 'sin_ejecutar' : ok ? 'ok' : 'fallo',
          atribucion: corrio ? 'Ejecutor local' : 'Sin ejecutar',
          stdout: textoDeBytes(p.stdout),
          stderr: textoDeBytes(p.stderr),
        });
        op.exitCode = exit;
        if (ok) resolverBloqueosDe(id);
        else {
          anotarBloqueo(
            corrio ? `Las pruebas de ${id} fallaron` : `Las pruebas de ${id} no llegaron a ejecutarse`,
            [texto(p.command), textoDeBytes(p.stderr), textoDeBytes(p.stdout)].filter(Boolean).join('\n'),
            'Abre la actividad para ver el comando y su salida.',
            id
          );
        }
        break;
      }

      case 'browser_gate_v1': {
        const pagina = texto(p.page) || 'la página';
        const corrio = p.ran === true;
        const veredicto = texto(p.verdict);
        const muertos = numero(p.dead_controls) ?? 0;
        const op = tocar(acc, `navegador:${pagina}`, 'navegador', ts, {
          titulo: `Comprobó ${pagina} en un navegador real`,
          taskId: '',
          estado: !corrio ? 'sin_ejecutar' : veredicto === 'pass' ? 'ok' : 'fallo',
          atribucion: corrio ? `Ejecutor local · ${texto(p.browser) || 'navegador'}` : 'Sin ejecutar',
        });
        // C1: una salida identica con entradas distintas es el falso verde de
        // la auditoría del 09-09. No tumba el veredicto —el alcance sigue
        // siendo efecto observable— pero el hecho se ve en el detalle.
        const invariantes = numero(p.controles_invariantes) ?? 0;
        op.detalle = corrio
          ? `${texto(p.files_checked)} archivo(s) leídos de disco · ${muertos} control(es) sin efecto` +
            (invariantes ? ` · ${invariantes} con la misma salida para entradas distintas` : '')
          : texto(p.reason);
        if (corrio && veredicto !== 'pass') {
          const controles = Array.isArray(p.controls) ? (p.controls as Array<Record<string, unknown>>) : [];
          const sinEfecto = controles
            .filter((c) => c.changed_dom !== true && !c.threw && !numero(c.errors))
            .map((c) => texto(c.control));
          anotarBloqueo(
            `La página entregada no responde en ${pagina}`,
            sinEfecto.length
              ? `Controles sin efecto al pulsarlos: ${sinEfecto.join(', ')}`
              : texto(p.reason) || 'La comprobación en navegador falló.',
            'Abre la actividad: la carpeta del gate contiene exactamente lo que se ejecutó.'
          );
        } else if (!corrio) {
          anotarBloqueo(
            'No se pudo comprobar la página en un navegador',
            texto(p.reason),
            'La orden NO queda verificada en navegador.'
          );
        }
        break;
      }

      case 'delegation_started_v1': {
        // USUARIO-NUEVO B: una línea por subtarea desde que se lanza.
        const subs = Array.isArray(p.subtasks) ? (p.subtasks as Array<Record<string, unknown>>) : [];
        for (const s of subs) {
          const idx = texto(s.index);
          const fallo = texto(s.setup_error);
          tocar(acc, `delegada:${idx}`, 'subagente', ts, {
            titulo: `Subtarea ${idx} · ${texto(s.role)}`,
            detalle: [texto(s.instruction), fallo ? `No arrancó: ${fallo}` : ''].filter(Boolean).join('\n'),
            estado: fallo ? 'fallo' : 'ejecutando',
            atribucion: texto(s.model) || 'Modelo que elija DevAgents',
            ordenHija: numero(s.child_order_id) || undefined,
          });
        }
        progreso.push(`Delegó ${subs.length} subtarea(s) en paralelo, cada una en su worktree.`);
        break;
      }
      case 'delegation_subtask_finished_v1': {
        const idx = texto(p.index);
        const id = `delegada:${idx}`;
        const st = texto(p.status);
        const veredicto = texto(p.verdict);
        const ms = numero(p.duration_ms);
        const archivos = Array.isArray(p.files) ? (p.files as unknown[]).map(texto).filter(Boolean) : [];
        const estadoOp: EstadoOperacion =
          st === 'done' && veredicto !== 'FAIL'
            ? 'ok'
            : st === 'cancelled'
              ? 'sin_ejecutar'
              : st === 'audit_unavailable'
                ? 'bloqueado'
                : 'fallo';
        const previa = acc.ops.get(id);
        const instruccion = previa ? previa.detalle.split('\n')[0] : '';
        tocar(acc, id, 'subagente', ts, {
          titulo: [`Subtarea ${idx}`, texto(p.role), ESTADO_SUBTAREA[st] ?? st, ms ? formatearDuracion(ms) : ''].filter(Boolean).join(' · '),
          detalle: [
            instruccion,
            texto(p.note),
            veredicto ? `Auditoría: ${veredicto}` : '',
            archivos.length ? `Archivos: ${archivos.join(', ')}` : '',
            texto(p.error),
          ].filter(Boolean).join('\n'),
          estado: estadoOp,
          atribucion: texto(p.model) || 'Modelo no declarado',
          ordenHija: numero(p.child_order_id) || undefined,
        });
        break;
      }
      case 'delegation_finished_v1': {
        const n = numero(p.count) ?? 0;
        const integradas = numero(p.integrated) ?? 0;
        progreso.push(
          p.cancelled === true
            ? 'Delegación detenida: las subtareas en marcha se cancelaron y no se integró nada.'
            : `Delegación terminada: ${integradas} de ${n} subtarea(s) integradas en la carpeta del proyecto.`
        );
        break;
      }
      case 'delegation_blocked_v1': {
        const causa = texto(p.cause);
        if (causa === 'no_git') {
          anotarBloqueo(
            'No se delegó: la carpeta no es un repositorio git',
            'Cada subtarea necesita su propio worktree para no pisar el trabajo de las demás; sin git no hay worktrees. El modelo sigue trabajando aquí, sin delegar.',
            'Pulsa «Iniciar git aquí» y vuelve a pedirlo.'
          );
        } else {
          anotarBloqueo('No se pudo preparar la delegación', `Causa del motor: ${causa || 'no declarada'}.`, 'La conversación sigue como en Directo.');
        }
        break;
      }

      case 'native_tool_result_v1': {
        // Los nombres de campo son los que emite el motor (`tool_name`,
        // `exit_code`, `timed_out`); adivinarlos dejaba la tarjeta sin título y
        // sin código de salida, que es justo lo que hay que poder auditar.
        //
        // D-C1 (E5.11): solo run_command devuelve exit_code. Las tools del
        // bucle agéntico —write_file/edit_file/finish/lecturas— informan
        // {ok, path, bytes, sha256, summary} o {error, detail}: sin exit_code
        // el estado sale de `error`/`ok`, nunca de un código ausente.
        const nombre = texto(p.tool_name ?? p.name ?? p.tool);
        // USUARIO-NUEVO B: el resultado de `delegate_tasks` ya está pintado
        // subtarea a subtarea (delegation_*); un rechazo (límite, rol, sin
        // git…) se dice en llano con su `detail`.
        if (nombre === 'delegate_tasks') {
          // `no_git` ya lo cuenta delegation_blocked_v1 con su acción.
          if (texto(p.error) && texto(p.error) !== 'no_git') {
            tocar(acc, `delegar:${acc.orden.length}`, 'subagente', ts, {
              titulo: 'No se delegó',
              detalle: texto(p.detail),
              estado: 'sin_ejecutar',
              atribucion: 'Motor de DevAgents',
            });
          }
          break;
        }
        const ruta = texto(p.path);
        // La clave de correlación incluye la ruta: dos write_file a archivos
        // distintos de la misma tarea son operaciones distintas, no una.
        const proceso = texto(p.process_id);
        const generacion = numero(p.lease_generation);
        if (proceso && generacion !== undefined && (p.background === true || nombre === 'process_stop')) {
          const key = `proceso:${proceso}`;
          const stopped = p.state !== 'running';
          const op = tocar(acc, key, 'herramienta', ts, {
            titulo: p.ok === false ? 'El proceso terminó con error' : !stopped ? 'Proceso iniciado en segundo plano' : p.state === 'stopped' ? 'Proceso detenido' : 'Proceso terminado',
            detalle: [texto(p.exe), texto(p.detail)].filter(Boolean).join(' — '),
            taskId: texto(p.task_id),
            estado: p.ok === false ? 'fallo' : 'ok',
            atribucion: 'Ejecutor local',
          });
          op.process = { id: proceso, generation: generacion, stopped };
          break;
        }
        const id = `herramienta:${texto(p.task_id)}:${nombre}:${ruta}`;
        const familia: Familia = HERRAMIENTAS_DE_LECTURA.has(nombre.toLowerCase()) ? 'lectura' : 'herramienta';
        const err = texto(p.error);
        if (err) {
          // USUARIO-NUEVO R2 (10-nov): el código del motor (`ExeNotAllowed`…)
          // no se pinta; `detail` lo explica en llano y nombra el ejecutable.
          // Remate D4: el rechazo se cuenta UNA vez, en su operación, con
          // contador si se repitió. Antes también era un bloqueo, y salía tres
          // veces (arriba, «ya visible arriba» y la operación) aunque no pide
          // nada al usuario: el agente sigue con otra acción.
          const veces = (rechazos.get(id) ?? 0) + 1;
          rechazos.set(id, veces);
          tocar(acc, id, familia, ts, {
            titulo: veces > 1 ? `No se pudo usar ${nombre} (${veces} veces)` : `No se pudo usar ${nombre}`,
            detalle: [texto(p.detail), ruta].filter(Boolean).join('\n'),
            taskId: texto(p.task_id),
            estado: 'fallo',
            atribucion: 'Ejecutor local · el agente puede seguir con otra acción',
          });
          break;
        }
        const exit = numero(p.exit_code);
        const agotado = p.timed_out === true;
        const ok = !agotado && p.is_error !== true && (exit === undefined ? p.ok !== false : exit === 0);
        const remate = agotado
          ? 'superó el tiempo límite'
          : !ok
            ? `terminó con código ${exit === undefined ? 'no informado' : exit}`
            : exit === undefined
              ? 'completada'
              : 'terminó correctamente';
        const detalleFichero = [
          ruta,
          numero(p.bytes) !== undefined ? `${numero(p.bytes)} B` : '',
          texto(p.summary),
          texto(p.detail),
        ].filter(Boolean).join(' — ');
        const op = tocar(acc, id, familia, ts, {
          titulo: p.finished === true ? `${nombre}: sesión agéntica cerrada` : `${nombre} ${remate}`,
          detalle: detalleFichero,
          taskId: texto(p.task_id),
          estado: agotado ? 'bloqueado' : ok ? 'ok' : 'fallo',
          atribucion: 'Ejecutor local',
          stdout: textoDeBytes(p.stdout),
          stderr: textoDeBytes(p.stderr),
        });
        op.exitCode = exit;
        if (!ok) {
          anotarBloqueo(
            `La herramienta ${nombre} ${remate}`,
            [texto(p.detail), textoDeBytes(p.stderr), textoDeBytes(p.stdout)].filter(Boolean).join('\n'),
            'Abre la actividad para ver su salida completa.',
            texto(p.task_id)
          );
        }
        break;
      }

      case 'agentic_unavailable': {
        // D-C1: el modelo asignado no tiene cap_tool_calls medida en vivo; la
        // tarea corrió sin tools. No es un fallo — es una degradación honesta
        // que el usuario debe poder ver.
        tocar(acc, `agentic:${texto(p.task_id)}`, 'herramienta', ts, {
          titulo: `Modo agéntico no disponible: ${texto(p.model) || 'modelo asignado'}`,
          detalle: texto(p.reason),
          taskId: texto(p.task_id),
          estado: 'ok',
          atribucion: 'Ejecutor local',
        });
        break;
      }

      case 'web_search':
      case 'web_search_failed': {
        const consulta = texto(p.query);
        tocar(acc, `busqueda:${consulta}`, 'busqueda', ts, {
          titulo: `Buscó: ${consulta}`,
          detalle: kind === 'web_search_failed' ? texto(p.reason) : texto(p.summary),
          estado: kind === 'web_search_failed' ? 'fallo' : 'ok',
          atribucion: 'Ejecutor local',
        });
        if (kind === 'web_search_failed') {
          anotarBloqueo(
            'La búsqueda en la web falló',
            [consulta, texto(p.reason)].filter(Boolean).join(' — '),
            'La respuesta no está verificada con una búsqueda en vivo.'
          );
        }
        break;
      }

      case 'subagent_stream_start':
      case 'subagent_stream_end': {
        const id = texto(p.subagent_id ?? p.task_id);
        tocar(acc, `subagente:${id}`, 'subagente', ts, {
          titulo: `Subagente ${id}`,
          detalle: texto(p.description),
          taskId: texto(p.task_id),
          estado: kind === 'subagent_stream_end' ? 'ok' : 'ejecutando',
          atribucion: atribucionDe(p, true, false),
        });
        break;
      }

      case 'open_design_run_started': {
        tocar(acc, `herramienta:open-design:${texto(p.task_id)}`, 'herramienta', ts, {
          titulo: 'Lanzó un run de Open Design',
          detalle: texto(p.result).slice(0, 400),
          taskId: texto(p.task_id),
          estado: 'ok',
          atribucion: 'Ejecutor local',
        });
        break;
      }

      case 'previewAvailable': {
        // El motor publica la URL de la vista previa de Open Design; sin caso
        // propio caía en «desconocidos» aun siendo un evento de producción
        // (hallazgo H-4 de la auditoría de cabina del 09-09).
        tocar(acc, `preview:${texto(p.task_id)}`, 'herramienta', ts, {
          titulo: 'Vista previa de diseño disponible',
          detalle: texto(p.url),
          taskId: texto(p.task_id),
          estado: 'ok',
          atribucion: 'Ejecutor local',
        });
        break;
      }

      // ── Diagnóstico técnico ───────────────────────────────────────────
      case 'local_json_retry':
      case 'local_json_fallback':
      case 'local_json_failed': {
        const quien = [texto(p.provider), texto(p.model)].filter(Boolean).join(' · ');
        const destino = [texto(p.to_provider), texto(p.to_model)].filter(Boolean).join(' · ');
        const motivo = texto(p.reason) || 'La respuesta no cumplió el formato JSON requerido.';
        tocar(acc, `local-json:${e.id}`, 'proveedor', ts, {
          titulo: kind === 'local_json_retry'
            ? 'Respuesta local no válida: un único reintento'
            : kind === 'local_json_fallback'
              ? 'Respuesta local no válida: cambio de modelo'
              : 'Respuesta local no válida: intentos agotados',
          detalle: [quien, motivo, destino ? `Siguiente modelo: ${destino}` : '', texto(p.contract)].filter(Boolean).join(' — '),
          estado: kind === 'local_json_failed' ? 'fallo' : 'bloqueado',
          atribucion: quien || 'Modelo local',
        });
        break;
      }
      case 'subscription_call_v1':
        tocar(acc, `suscripcion:${e.id}`, 'proveedor', ts, {
          titulo: `Suscripción · ${texto(p.provider)} · ${texto(p.model)}`,
          detalle: 'Consume cuota de la suscripción; sin coste por llamada. Tokens no medidos en este transporte.',
          estado: p.success === true ? 'ok' : 'fallo',
          atribucion: texto(p.role),
        });
        break;
      case 'provider_failed':
      case 'task_provider_failed':
      case 'provider_contract_abort': {
        const quien = [texto(p.provider), texto(p.model)].filter(Boolean).join(' · ') || 'proveedor';
        tocar(acc, `proveedor:${quien}`, 'proveedor', ts, {
          titulo: `Proveedor ${quien}`,
          detalle: [p.http_status != null ? `HTTP ${texto(p.http_status)}` : '', texto(p.reason), texto(p.excerpt), texto(p.error_name ?? p.error)].filter(Boolean).join(' — '),
          estado: 'fallo',
          atribucion: quien,
        });
        break;
      }
      case 'task_provider_ok': {
        const quien = [texto(p.provider), texto(p.model)].filter(Boolean).join(' · ') || 'proveedor';
        tocar(acc, `proveedor:${quien}`, 'proveedor', ts, {
          titulo: `Proveedor ${quien}`,
          detalle: 'respondió',
          estado: 'ok',
          atribucion: quien,
        });
        break;
      }
      case 'provider_fallback': {
        // un cambio de modelo declara quién falló, con qué motivo
        // y a quién se pasó el trabajo. En la orden #890 el ejecutor fijado
        // (Claude Code) falló y la tarjeta solo decía «el router degradó al
        // siguiente» — el respaldo quedaba invisible para el usuario.
        const fallo = [texto(p.from_provider), texto(p.from_model)].filter(Boolean).join(' · ');
        const siguiente = [texto(p.to_provider), texto(p.to_model)].filter(Boolean).join(' · ');
        const motivo = texto(p.reason) || texto(p.status);
        tocar(acc, 'proveedor:fallback', 'proveedor', ts, {
          titulo: 'Cambió de modelo',
          detalle: [
            fallo ? `falló ${fallo}` : 'El proveedor no respondió',
            motivo,
            siguiente ? `siguió ${siguiente}` : 'el router degradó al siguiente',
          ].filter(Boolean).join(' — '),
          estado: 'bloqueado',
          atribucion: 'Router',
        });
        break;
      }
      case 'semantic_gate_v1':
        // Verificación semántica determinista: ran=false también es información
        // (explica por qué el veredicto es solo del gate determinista).
        tocar(acc, 'verificacion:semantica', 'auditoria', ts, {
          titulo: p.ran === true ? 'Verificación semántica ejecutada' : 'Verificación semántica omitida',
          detalle: texto(p.reason ?? p.verdict ?? p.summary),
          estado: p.ran === false ? 'bloqueado' : 'ok',
        });
        break;
      case 'plan_audit_enforced_v1': {
        // la orden pedía una auditoría y el plan no traía ninguna.
        const deps = Array.isArray(p.depends_on) ? (p.depends_on as unknown[]).map(texto).join(', ') : '';
        tocar(acc, 'verificacion:auditoria-final', 'auditoria', ts, {
          titulo: 'El motor añadió la tarea de auditoría',
          detalle: `La orden pide una auditoría y el plan no traía ninguna${deps ? `; audita después de ${deps}` : ''}.`,
          estado: 'ok',
          atribucion: 'Motor',
        });
        break;
      }
      case 'audit_citations_v1': {
        // cada archivo:línea del informe, abierto y comprobado.
        const total = Number(p.citas ?? 0);
        const fallidas = Number(p.fallidas ?? 0);
        tocar(acc, `verificacion:citas:${texto(p.task_id)}`, 'auditoria', ts, {
          titulo: fallidas > 0
            ? `${fallidas} de ${total} citas del auditor no se sostienen`
            : `Citas del auditor comprobadas: ${total}`,
          detalle: fallidas > 0
            ? texto(p.detalle)
            : `${Number(p.verificadas ?? 0)} con el texto en su línea, ${Number(p.solo_existencia ?? 0)} sin texto citado (archivo y línea existen).`,
          estado: fallidas > 0 ? 'fallo' : 'ok',
          atribucion: 'Motor',
        });
        break;
      }
      case 'rate_limit_retry':
        // USUARIO-NUEVO A6 (10-nov): los reintentos y el fallo final de un
        // mismo modelo son UNA operación («Probó 1 proveedor»), no dos; el
        // `provider_failed` posterior la cierra con su motivo.
        tocar(acc, `proveedor:${[texto(p.provider), texto(p.model)].filter(Boolean).join(' · ') || 'proveedor'}`, 'proveedor', ts, {
          titulo: 'Límite de peticiones — reintentando',
          detalle: [texto(p.provider), texto(p.model), texto(p.wait_ms ? `espera ${p.wait_ms} ms` : '')].filter(Boolean).join(' · '),
          estado: 'ejecutando',
          atribucion: atribucionDe(p, true, false),
        });
        break;
      case 'ship_started':
        tocar(acc, 'entrega:ship', 'tarea', ts, {
          titulo: 'Entrega en curso',
          detalle: texto(p.summary ?? p.detail),
          estado: 'ejecutando',
        });
        break;
      case 'ship_done':
      case 'ship_failed':
        tocar(acc, 'entrega:ship', 'tarea', ts, {
          titulo: kind === 'ship_done' ? 'Entrega completada' : 'La entrega falló',
          detalle: texto(p.summary ?? p.error ?? p.reason),
          estado: kind === 'ship_done' ? 'ok' : 'fallo',
        });
        break;
      case 'clarify_exhausted':
        anotarBloqueo(
          'La aclaración llegó a su límite',
          texto(p.reason ?? p.message),
          'Reformula la orden con más detalle y reintenta.'
        );
        break;
      case 'planner_fallback':
        // `reason` es el código de máquina («mock_planner»); `detail` lleva la
        // causa real escrita para personas (sin clave, timeout, JSON sin plan).
        // Los eventos de runs antiguos no traen detail: se traduce el código.
        anotarBloqueo(
          tituloDiagnostico(kind),
          texto(p.detail) ||
            (texto(p.reason) === 'mock_planner'
              ? 'El modelo no pudo planificar; se usó el planificador local del motor.'
              : texto(p.reason ?? p.error ?? p.error_msg ?? p.message)),
          'Detalle técnico dentro de la actividad.'
        );
        break;
      case 'provider_exhausted':
        if (esDirecto) break;
      // falls through
      case 'dispatch_failed':
      case 'native_tool_session_failed_v1':
      case 'native_tool_session_stopped_v1':
      case 'artifact_incoherent':
      case 'design_degraded':
      case 'open_design_submit_failed':
        anotarBloqueo(
          tituloDiagnostico(kind),
          texto(p.reason ?? p.error ?? p.error_msg ?? p.detail ?? p.message),
          'Detalle técnico dentro de la actividad.',
          '',
          kind === 'provider_exhausted' ||
            kind === 'native_tool_session_failed_v1' ||
            kind === 'native_tool_session_stopped_v1'
        );
        break;
      case 'budget_blocked_v1':
        anotarBloqueo(
          'Cupo de llamadas de pago agotado',
          [texto(p.model), texto(p.reason)].filter(Boolean).join(' — '),
          'Autorizar más llamadas en Configuración → Gobernanza, o cambiar a gratis/suscripción.'
        );
        break;
      case 'governance_blocked_v1':
        // La gobernanza no pide permiso: IMPIDE. Tratarlo como «aprobación
        // pendiente» dejaba al usuario esperando un botón que no existe.
        anotarBloqueo(
          'La gobernanza bloqueó la llamada',
          [texto(p.model ?? p.tool ?? p.exe), texto(p.reason)].filter(Boolean).join(' — '),
          'Cambia la política de coste o el modelo fijado en Configuración.'
        );
        break;
      case 'approval_needed':
      case 'approval_required':
      {
        const id = Number(p.approval_id);
        pendientes.push({
          tipo: 'aprobacion',
          titulo: 'Hace falta tu aprobación',
          detalle: [texto(p.tool ?? p.exe ?? p.command), texto(p.reason)].filter(Boolean).join(' — '),
          ...(Number.isSafeInteger(id) && id > 0 ? { approvalId: id } : {}),
        });
        break;
      }
      // (tanda 1): una aprobación contestada o cerrada deja de
      // esperar al usuario. Antes la tarjeta seguía en el hilo tras resolverla.
      case 'approval_resolved':
      case 'approval_closed': {
        const id = Number(p.approval_id);
        const i = pendientes.findIndex((x) => x.approvalId === id);
        if (i >= 0) pendientes.splice(i, 1);
        break;
      }
      case 'content_delta':
      case 'worker_output':
      case 'subagent_stream_chunk':
      case 'cross_turn_event':
        // Corriente cruda: vive en el registro completo, no en la conversación.
        break;

      // ── Razonamiento ──────────────────────────────────────────────────
      case 'reasoning_delta': {
        const t = texto(p.text ?? p.delta ?? p.content ?? p.reasoning);
        if (t) razonamientoTrozos.push(t);
        const quien = [texto(p.provider), texto(p.model)].filter(Boolean).join(' · ');
        if (quien && !razonamientoProcedencia) razonamientoProcedencia = quien;
        break;
      }

      // ── Estados terminales y respuesta ────────────────────────────────
      case 'order_done':
        estado = 'completado';
        break;
      case 'order_failed': {
        estado = 'fallido';
        // El fallo de la orden es el TITULAR. Una causa de nivel ORDEN
        // (despacho rechazado, gate semántico, aprobaciones) no la explica
        // ningún bloqueo de tarea: se muestra siempre. Medido en la incidencia
        // del plan local — con el bloqueo de planner_fallback presente, la
        // causa real (`selected_model_unavailable`) no aparecía en NINGÚN
        // sitio y el usuario solo veía «El plan no lo generó un modelo».
        // Las causas de tarea (all_tasks_failed, browser_gate_failed…) ya las
        // cuentan sus bloqueos concretos; repetirlas sería ruido.
        const causa = texto(p.cause ?? p.error_msg ?? p.reason);
        const humana = CAUSA_FALLO_ORDEN[causa];
        if (esDirecto && /^Directo:/.test(texto(p.reason))) break;
        if (p.reason || bloqueos.length === 0 || CAUSA_SIN_BLOQUEO_PROPIO.has(causa)) {
          anotarBloqueo(
            humana?.titulo ?? 'La orden terminó con errores',
            texto(p.reason) || (humana ? humana.detalle : causa),
            humana?.accion ?? 'Revisa la actividad para ver en qué paso se detuvo.'
          );
        }
        break;
      }
      case 'order_cancelled':
        estado = 'cancelado';
        break;
      case 'order_audit_unavailable_v1':
        estado = 'sin_auditar';
        anotarBloqueo(
          'Ejecución conservada; auditoría no disponible',
          'La orden terminó sin un veredicto de auditoría usable — no hay aprobación ni rechazo del entregable.',
          'Reintenta la auditoría cuando el proveedor de auditoría esté disponible.'
        );
        break;
      case 'agent_message':
        break;
      default:
        break;
    }
  }

  // El éxito NO se infiere de que dejara de llegar nada. Un turno que ya no
  // está vivo y no trajo evento terminal quedó interrumpido, y eso se dice.
  if (estado === 'ejecutando' && !opciones.vivo) {
    estado = events.length ? 'interrumpido' : 'interrumpido';
  }
  // Un turno terminado ya no espera ninguna respuesta: una solicitud que
  // caducó con la orden no se queda pidiendo «tu aprobación».
  if (estado !== 'ejecutando') pendientes.length = 0;
  if (estado === 'ejecutando' && pendientes.length > 0) estado = 'esperando';
  // Una orden completada se recuperó de sus fallos intermedios.
  if (estado === 'completado') {
    for (const b of bloqueos) if (b.recuperable) b.resuelto = true;
  }

  const operaciones = acc.orden.map((id) => acc.ops.get(id)!);
  // Una operación que se quedó `ejecutando` cuando el turno ya no está vivo no
  // terminó bien: terminó sin decirlo.
  if (!opciones.vivo) {
    for (const op of operaciones) {
      if (op.estado === 'ejecutando') op.estado = 'sin_ejecutar';
    }
  }

  const grupos = agruparOperaciones(operaciones);
  const finReal = fin || opciones.ahora;
  const transcurridoMs = inicio ? Math.max(0, (opciones.vivo ? opciones.ahora : finReal) - inicio) : 0;

  return {
    estado,
    inicio,
    fin: finReal,
    transcurridoMs,
    operaciones,
    grupos,
    progreso,
    bloqueos,
    pendientes,
    razonamiento: razonamientoTrozos.length
      ? {
          texto: razonamientoTrozos.join(''),
          // Si el proveedor no dijo quién razonó, se dice ESO, no un nombre.
          procedencia: razonamientoProcedencia || 'procedencia no declarada por el proveedor',
        }
      : null,
    desconocidos,
    acciones: operaciones.length,
    eventos: events.length,
  };
}

/**
 * Traducción de `order_failed.cause` (código de máquina del motor) a titular +
 * detalle + acción para personas. Las causas no mapeadas se muestran crudas —
 * ocultarlas fue exactamente el fallo de la incidencia del plan local.
 */
const CAUSA_FALLO_ORDEN: Record<string, { titulo: string; detalle: string; accion: string }> = {
  selected_model_unavailable: {
    titulo: 'El modelo elegido no está disponible',
    detalle: 'Al ejecutar, el modelo fijado no tenía candidato con clave activa.',
    accion: 'Fija otro modelo o revisa su clave y la política de coste en Configuración.',
  },
  paid_budget_exhausted: {
    titulo: 'Cupo de llamadas de pago agotado',
    detalle: 'La solicitud se bloqueó antes de enviarse al proveedor.',
    accion: 'Autorizar más llamadas en Configuración → Gobernanza, o cambiar a gratis/suscripción.',
  },
  all_tasks_failed: {
    titulo: 'Todas las tareas terminaron con error',
    detalle: 'Ninguna tarea del plan llegó a completarse.',
    accion: 'Revisa la actividad para ver en qué paso se detuvo cada una.',
  },
  tasks_failed: {
    titulo: 'Parte de las tareas terminaron con error',
    detalle: 'El plan completó una parte del trabajo, pero no todo.',
    accion: 'Revisa la actividad para ver qué tarea falló y reintenta la orden.',
  },
  execution_failed: {
    titulo: 'La ejecución falló',
    detalle: 'El despacho de la orden no pudo completarse.',
    accion: 'Revisa la actividad para ver en qué paso se detuvo.',
  },
  semantic_gate_failed: {
    titulo: 'La verificación semántica rechazó el resultado',
    detalle: 'Lo producido no cumple lo que la orden pedía.',
    accion: 'Revisa las diferencias declaradas en la actividad.',
  },
  approvals_resolved: {
    titulo: 'La orden no quedó aprobada para ejecutar',
    detalle: 'Las aprobaciones se resolvieron sin dejar la orden en estado ejecutable.',
    accion: 'Revisa la actividad para ver qué aprobación la detuvo.',
  },
  validation_failed: {
    titulo: 'El resultado no pasó la validación',
    detalle: 'Un artefacto no cumplió el contrato de su tarea.',
    accion: 'Revisa la actividad para ver qué artefacto falló.',
  },
};

/**
 * Causas de `order_failed` que NINGÚN bloqueo de tarea puede explicar: las
 * emite la maquinaria de la orden (despacho, gate, aprobaciones), no una tarea
 * que falló. Estas se muestran aunque ya haya otros bloqueos; el resto solo
 * cuando no hay nada más concreto que lo cuente.
 */
const CAUSA_SIN_BLOQUEO_PROPIO = new Set([
  'selected_model_unavailable',
  'semantic_gate_failed',
  'approvals_resolved',
]);

/**
 * Traducción de `task_failed.cause` a texto humano. Las no mapeadas se muestran
 * crudas — ocultar la causa real fue el fallo central de esta incidencia.
 */
const CAUSA_FALLO_TAREA: Record<string, string> = {
  worker_failed: 'El worker no pudo ejecutarla',
  validation_failed: 'El resultado no cumplió el contrato',
  execution_failed: 'La ejecución falló',
  execution_timeout: 'La ejecución agotó su tiempo',
  approval_required: 'Requería una aprobación que no llegó',
  ui_action_rejected: 'La acción de UI fue rechazada',
  // E5.04: causas del evento worktree_setup_failed.
  invalid_config: 'La configuración del worktree no es válida',
  pending_approval: 'El script de setup espera aprobación',
  executor_rejected: 'El ejecutor rechazó el script de setup',
  setup_failed: 'El script de setup terminó mal',
  CopyPathEscape: 'Una ruta de copia se sale de las raíces',
  CopyNotRegular: 'Una ruta de copia no es un archivo regular',
  CopyTooLarge: 'Un archivo de copia supera 1 MiB',
  CopyTooMany: 'La lista de copia supera 50 archivos',
  CopyFailed: 'La copia al worktree falló',
  SetupScriptInvalid: 'El script de setup no es válido',
};

function tituloDiagnostico(kind: string): string {
  switch (kind) {
    case 'provider_exhausted':
      return 'Ningún proveedor respondió';
    case 'dispatch_failed':
      return 'El despacho no pudo arrancar';
    case 'planner_fallback':
      return 'El plan no lo generó un modelo';
    case 'native_tool_session_failed_v1':
      return 'La sesión de herramientas nativas falló';
    case 'native_tool_session_stopped_v1':
      return 'La sesión de herramientas nativas se detuvo';
    case 'artifact_incoherent':
      return 'El entregable enlaza algo que no entrega';
    case 'design_degraded':
      return 'El puente de diseño no está disponible';
    case 'open_design_submit_failed':
      return 'No se pudo enviar el run de diseño';
    default:
      return kind;
  }
}

export function agruparOperaciones(operaciones: Operacion[]): ResumenGrupo[] {
  const cuenta = new Map<Familia, number>();
  for (const op of operaciones) cuenta.set(op.familia, (cuenta.get(op.familia) ?? 0) + 1);
  const out: ResumenGrupo[] = [];
  for (const [familia, n] of cuenta) {
    const [uno, varios] = ETIQUETA_GRUPO[familia];
    out.push({ familia, cantidad: n, etiqueta: n === 1 ? uno : varios.replace('{n}', String(n)) });
  }
  return out;
}

/** «2 min 14 s», «14 s». Sin decimales inventados. */
export function formatearDuracion(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  if (total < 60) return `${total} s`;
  const min = Math.floor(total / 60);
  const seg = total % 60;
  return seg ? `${min} min ${seg} s` : `${min} min`;
}

const VERBO_ESTADO: Record<EstadoTurno, string> = {
  ejecutando: 'Trabajando desde hace',
  completado: 'Trabajó durante',
  fallido: 'Falló tras',
  cancelado: 'Cancelado tras',
  interrumpido: 'Interrumpido tras',
  sin_auditar: 'Sin auditar tras',
  esperando: 'Esperando tu respuesta tras',
};

/**
 * El resumen de una línea del bloque plegado. Cuenta ACCIONES (operaciones),
 * no eventos: 300 eventos de streaming de un comando son una acción.
 */
export function resumenActividad(a: ActividadTurno): string {
  // QA primerizo (11-nov): «· 0 acciones» en un turno que solo conversó (o
  // cuyas acciones no se registran como operaciones) parecía un fallo; sin
  // acciones el resumen dice solo cuánto trabajó.
  const base = `${VERBO_ESTADO[a.estado]} ${formatearDuracion(a.transcurridoMs)}`;
  if (a.acciones <= 0) return base;
  const acciones = a.acciones === 1 ? '1 acción' : `${a.acciones} acciones`;
  return `${base} · ${acciones}`;
}

/**
 * USUARIO-NUEVO A7 (10-nov): la línea del grupo plegable entre el mensaje y la
 * respuesta, como en otras IDE: «Ejecutó 4 comandos · escribió 2 archivos ·
 * 38 s». Dice QUÉ hizo, no cuántos eventos emitió el motor.
 */
export function resumenTrabajo(a: ActividadTurno): string {
  const grupos = a.grupos.map((g, i) => (i === 0 ? g.etiqueta : g.etiqueta.charAt(0).toLowerCase() + g.etiqueta.slice(1)));
  const duracion = formatearDuracion(a.transcurridoMs);
  if (!grupos.length) return `${VERBO_ESTADO[a.estado]} ${duracion}`;
  const prefijo = a.estado === 'ejecutando' ? 'Trabajando · ' : a.estado === 'fallido' ? 'Falló · ' : a.estado === 'cancelado' ? 'Cancelado · ' : '';
  // Menos de un segundo (o eventos sin hora fina) no aporta: «· 0 s» parecía
  // que no había trabajado.
  return a.transcurridoMs >= 1000 ? `${prefijo}${grupos.join(' · ')} · ${duracion}` : `${prefijo}${grupos.join(' · ')}`;
}

/**
 * A7: ¿hubo trabajo que enseñar? Operaciones reales, algo que espera al
 * usuario o un bloqueo vigente. Un turno que solo conversó no pinta grupo:
 * ni «Trabajó durante 2 s» ni contadores de eventos (eso queda en «Registro
 * completo»).
 */
export function hayTrabajo(a: ActividadTurno): boolean {
  return a.operaciones.length > 0 || a.pendientes.length > 0 || bloqueosVigentes(a).length > 0;
}

/**
 * ¿Debe plegarse solo? Sí cuando el turno alcanzó un estado terminal y no hay
 * nada que exija intervención. Un turno vivo, uno con aprobación pendiente y
 * uno con bloqueos sin resolver se quedan abiertos.
 */
export function deberiaPlegarse(a: ActividadTurno): boolean {
  if (a.estado === 'ejecutando' || a.estado === 'esperando') return false;
  if (a.pendientes.length > 0) return false;
  return true;
}

/** Bloqueos que siguen importando: los no resueltos, en orden de aparición. */
export function bloqueosVigentes(a: ActividadTurno): Bloqueo[] {
  return a.bloqueos.filter((b) => !b.resuelto);
}

function basename(p: string): string {
  const i = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return i >= 0 ? p.slice(i + 1) : p;
}

// ── Consolas por worker (F3 · consolas paralelas) ──────────────────────────

/**
 * Una consola por worker/tarea: la salida cruda que el motor emite como
 * `worker_output` agrupada por quien la produjo.
 *
 * La clave es, en este orden, `task_id` → `worker_id` → `stream`: la orden
 * 533 demostró que los trozos en vivo llevan `task_id` y los volcados finales
 * pueden no traerlo, así que el agrupador no exige un campo concreto.
 */
export interface ConsolaWorker {
  /** Clave estable de agrupación. */
  id: string;
  /** Nombre visible: la tarea, el worker o el stream que sea. */
  nombre: string;
  /** Stream dominante: stdout, stderr, reporte… */
  stream: string;
  /** Texto concatenado en orden de llegada. */
  texto: string;
  /** Cuántos eventos worker_output se plegaron aquí. */
  trozos: number;
  /** true cuando el texto se capó por tamaño (se conserva el final). */
  capado: boolean;
}

const CONSOLA_CAP_BYTES = 64 * 1024;

/**
 * Agrupa los `worker_output` de un turno en consolas paralelas.
 *
 * Sin ellas la salida de cada worker se diluía en la traza global y F8 no se
 * podía VER: doce trabajadores producen doce corrientes que el usuario debe
 * poder leer por separado. Los eventos ya llegan por `order_events`; aquí solo
 * se reagrupan — el motor ya hizo el trabajo de emitirlos por trozo.
 *
 * El cap conserva el FINAL del texto: lo reciente es lo que explica en qué
 * quedó el worker; el principio se marca como truncado, no se borra a ciegas.
 */
export function consolasDeWorkers(events: OrderEvent[], capBytes = CONSOLA_CAP_BYTES): ConsolaWorker[] {
  const porClave = new Map<string, ConsolaWorker>();
  for (const ev of events) {
    if (String(ev?.kind ?? '') !== 'worker_output') continue;
    const payload = eventPayload(ev);
    const taskId = String(payload.task_id ?? '').trim();
    const workerId = String(payload.worker_id ?? '').trim();
    const stream = String(payload.stream ?? '').trim() || 'stdout';
    const id = taskId || workerId || stream;
    const texto = String(payload.text ?? payload.chunk ?? '');
    if (!texto) continue;
    let consola = porClave.get(id);
    if (!consola) {
      consola = {
        id,
        nombre: taskId || workerId || stream,
        stream,
        texto: '',
        trozos: 0,
        capado: false,
      };
      porClave.set(id, consola);
    }
    consola.texto += texto;
    consola.trozos += 1;
  }
  const consolas = [...porClave.values()];
  for (const c of consolas) {
    if (c.texto.length > capBytes) {
      c.texto = `[… ${c.texto.length - capBytes} caracteres iniciales truncados …]\n` + c.texto.slice(-capBytes);
      c.capado = true;
    }
  }
  return consolas;
}
