/**
 * ui_diag.ts — Diagnóstico legible de eventos, SIN dependencias del DOM.
 *
 * Sale del centro de mando a propósito para poder probarse sola: las dos
 * funciones son las que deciden qué se le dice al usuario sobre un fallo. Si
 * el texto siguiera dentro de mission_control.ts, solo un arnés con WebView2
 * podría comprobar lo que dice — exactamente el problema de "no sirvió:
 * empty" que pasaba desapercibido porque nadie podía verlo.
 */
import { OrderEvent, eventPayload } from './bridge/core_api';

/** Only the engine's root snapshot rejection offers the explicit ACL repair. */
export function workspaceRestoreDiagnostic(events: OrderEvent[]): string | null {
  const event = [...events].reverse().find(e => e.kind === 'external_agent_finished');
  if (!event) return null;
  const diagnostic = eventPayload(event).error;
  if (typeof diagnostic !== 'string' ||
      !diagnostic.startsWith('snapshot: fallo; etapa=raiz; ruta=.; error=CliWritableByOthers;') ||
      !diagnostic.includes('accion=workspace_acl_restore')) return null;
  return diagnostic;
}

/**
 * Clasificación de los eventos de una orden en los TRES niveles de P4.
 * Pura, sin DOM ni localStorage, para poder probarse sola — es la lógica de
 * "el chat cuenta la historia, no el mecanismo".
 */
export interface ActionBuckets {
  /** Siempre visibles: plan, archivos, procesos, resultado, primer error. */
  fijos: Array<{ titulo: string; detalle: string; color: string; abrir?: string }>;
  /** Olas (ya filtradas del razonamiento). */
  olas: string[];
  /** Tareas individuales (sin el primer error, que va a fijos). */
  tareas: Array<{ titulo: string; detalle: string; fallida: boolean }>;
  /** Comprobaciones exitosas, agrupadas para no competir con el resultado. */
  verificaciones: Array<{ titulo: string; detalle: string }>;
  /** Intentos de proveedor. */
  proveedores: Array<{ titulo: string; detalle: string; ok: boolean }>;
  fallbacks: number;
  proveedoresDistintos: number;
  proveedoresFallidos: number;
  primerError: { titulo: string; detalle: string } | null;
}

/** Dice si un kind de evento representa un fallo (para never-auto-collapse). */
export function esKindError(kind: string): boolean {
  return /fail|error|cancel|abort/i.test(kind);
}

/**
 * Reparte los eventos de una orden por niveles. Un grupo SOLO se considera
 * "con errores" (y por tanto nunca plegado solo) si sus propios eventos son
 * fallos; los `task_provider_failed` de un fallback normal cuentan como ruido
 * del mecanismo salvo que ningún proveedor haya respondido.
 */
export function classifyActions(events: OrderEvent[]): ActionBuckets {
  const fijos: ActionBuckets['fijos'] = [];
  const olas: string[] = [];
  const tareas: ActionBuckets['tareas'] = [];
  const verificaciones: ActionBuckets['verificaciones'] = [];
  const proveedores: ActionBuckets['proveedores'] = [];
  let fallbacks = 0;
  let proveedoresDistintos = 0;
  let proveedoresFallidos = 0;
  let primerError: ActionBuckets['primerError'] = null;
  const proveedoresVistos = new Map<string, boolean>();

  const capturaPrimerError = (titulo: string, detalle: string): void => {
    if (!primerError) primerError = { titulo, detalle };
  };

  for (const e of events) {
    const p = eventPayload(e);
    const kind = String(e.kind || '');
    switch (kind) {
      case 'superagent_thinking': {
        const txt = String(p.text ?? '');
        if (/^Ola \d/i.test(txt)) olas.push(txt);
        break;
      }
      case 'task_started': {
        const modelo = [p.provider, p.model].filter(Boolean).join(' · ');
        tareas.push({
          titulo: `Tarea ${String(p.task_id ?? '')} · ${String(p.department ?? p.task_type ?? '')}`,
          detalle: [String(p.description ?? ''), modelo].filter(Boolean).join('  —  '),
          fallida: false,
        });
        break;
      }
      // B6: el veredicto del auditor, A LA VISTA.
      //
      // Antes solo iba a `audit_ledger`, que el usuario no abre nunca: la orden
      // #283 cerro en `done` con el auditor diciendo FAIL sobre codigo correcto y
      // por pantalla no se veia nada. No bloquea el flujo (decision B6 opcion b),
      // pero un FAIL va en rojo y NUNCA se pliega: quien decide reintentar es el
      // usuario, y para decidir tiene que enterarse.
      case 'task_audit': {
        const veredicto = String(p.verdict ?? '').toUpperCase();
        const falla = veredicto === 'FAIL';
        const quien = [String(p.provider ?? ''), String(p.model ?? '')].filter(Boolean).join(' · ');
        const auditoria = {
          titulo: `Auditoria de la tarea ${String(p.task_id ?? '')}: ${veredicto || 'sin veredicto'}`,
          detalle: [quien, String(p.notes ?? '')].filter(Boolean).join('  —  '),
        };
        if (falla) fijos.push({ ...auditoria, color: 'var(--danger)' });
        else if (veredicto === 'PASS') verificaciones.push(auditoria);
        else fijos.push({ ...auditoria, color: 'var(--warning)' });
        break;
      }
      case 'task_audit_unavailable_v1': {
        // El auditor no entregó veredicto usable: se enseña como pendiente,
        // no como PASS ni FAIL. La entrega sigue bloqueada.
        fijos.push({
          titulo: `Auditoría de la tarea ${String(p.task_id ?? '')}: sin veredicto`,
          detalle: 'El proveedor de auditoría no respondió con un veredicto usable. Reintenta la auditoría para poder entregar.',
          color: 'var(--warning)',
        });
        break;
      }
      case 'test_evidence_v1': {
        const ok = p.ran === true && Number(p.exit_code) === 0 && p.timed_out !== true;
        const titulo = `Prueba de ${String(p.producer_task_id ?? '')}: ${ok ? 'correcta' : p.ran !== true ? 'sin ejecutar' : p.timed_out === true ? 'tiempo agotado' : `falló (código ${String(p.exit_code)})`}`;
        const detalle = [String(p.command ?? ''), `Revisión ${String(p.producer_revision ?? '')}`,
          String(p.stdout ?? ''), String(p.stderr ?? '')].filter(Boolean).join('\n');
        if (ok) verificaciones.push({ titulo, detalle });
        else {
          fijos.push({ titulo, detalle, color: p.ran === true ? 'var(--danger)' : 'var(--warning)' });
          capturaPrimerError(titulo, detalle);
        }
        break;
      }
      case 'file_written':
        fijos.push({
          titulo: `Escribió ${basename(String(p.file_path ?? p.artifact_name ?? ''))}`,
          detalle: String(p.file_path ?? ''),
          color: 'var(--success)',
          // S7: la tarjeta enseñaba la ruta y nada más. Pedir «hazme una
          // calculadora» y que el resultado sea un texto con una ruta que hay
          // que copiar a mano es el último tramo del recorrido, y estaba sin
          // hacer. Con la ruta absoluta, `shell.open` la abre con la aplicación
          // que corresponda: el navegador si es un .html, el editor si no.
          abrir: String(p.file_path ?? ''),
        });
        break;
      case 'shell_command': {
        const status = String(p.status ?? '').toLowerCase();
        const command = String(p.command ?? '').trim();
        const file = String(p.file ?? '').trim();
        const target = [command, file].filter(Boolean).join(' ');
        // Los deltas y el arranque ya se ven en la salida del motor; repetirlos
        // como tarjetas crea filas vacías y desplaza los resultados.
        if (status === 'running' || status === 'delta' || !target) break;
        if (status === 'done') {
          const exitCode = typeof p.exit_code === 'number' ? p.exit_code : Number.NaN;
          const ok = Number.isFinite(exitCode) && exitCode === 0 && p.timed_out !== true;
          const detalle = [
            Number.isFinite(exitCode) ? `Código de salida: ${exitCode}` : 'Código de salida no informado',
            String(p.stdout ?? ''),
            String(p.stderr ?? ''),
          ].filter(Boolean).join('\n');
          if (p.timed_out === true) {
            fijos.push({ titulo: `Comando detenido por tiempo: ${target}`, detalle, color: 'var(--warning)' });
          } else if (ok) verificaciones.push({ titulo: `Comando correcto: ${target}`, detalle });
          else {
            const titulo = `Comando falló: ${target}`;
            fijos.push({ titulo, detalle, color: 'var(--danger)' });
            capturaPrimerError(titulo, detalle);
          }
          break;
        }
        // Eventos previos al protocolo con status conservan una tarjeta útil.
        if (!status) fijos.push({ titulo: `Ejecutó ${target}`, detalle: '', color: 'var(--accent)' });
        break;
      }
      case 'process_launched':
        fijos.push({
          titulo: `Lanzó ${String(p.file ?? '')} (PID ${String(p.pid ?? '?')})`,
          detalle: String(p.mode ?? '') === 'detached' ? 'proceso independiente' : '',
          color: 'var(--success)',
        });
        break;
      case 'task_done':
        if (p.success === false) {
          capturaPrimerError(
            `Tarea ${String(p.task_id ?? '')} fallida`,
            String(p.error_msg ?? p.cause ?? '')
          );
        } else {
          verificaciones.push({
            titulo: `Tarea ${String(p.task_id ?? '')} completada`,
            detalle: String(p.model_used ?? ''),
          });
        }
        break;
      case 'task_failed':
        capturaPrimerError(
          `Tarea ${String(p.task_id ?? '')} fallida`,
          String(p.error_msg ?? p.cause ?? '')
        );
        break;
      case 'task_provider_ok':
      case 'task_provider_failed':
      case 'provider_failed': {
        const cuenta = String(p.key_label ?? '');
        const ok = kind === 'task_provider_ok';
        const proveedor = String(p.provider ?? '');
        if (proveedor && !proveedoresVistos.has(proveedor)) {
          proveedoresVistos.set(proveedor, ok);
          proveedoresDistintos += 1;
        }
        if (proveedor && !ok) proveedoresFallidos += 1;
        proveedores.push({
          titulo: `${proveedor} · ${String(p.model ?? '')}${cuenta ? ` (${cuenta})` : ''}`,
          detalle: ok ? 'respondió correctamente' : describeProviderFailure(p),
          ok,
        });
        break;
      }
      case 'provider_fallback':
        fallbacks += 1;
        break;
      case 'provider_exhausted':
        capturaPrimerError('Ningún proveedor respondió', String(p.message ?? ''));
        break;
      case 'provider_contract_abort':
        capturaPrimerError(
          `Cadena detenida tras ${String(p.providers_empty ?? 0)} proveedores sin respuesta usable`,
          String(p.message ?? '')
        );
        break;
      case 'agent_message': {
        const text = String(p.text ?? '');
        const exit = /^exit=(-?\d+)(?:\r?\n|$)/.exec(text);
        // Solo los diagnósticos estructurados del motor se resumen. El resto
        // puede ser conversación legítima y se conserva íntegro como título.
        if (!exit) {
          fijos.push({ titulo: text, detalle: '', color: 'var(--accent)' });
          break;
        }
        const exitCode = Number(exit[1]);
        const titulo = exitCode === 0 ? 'Proceso terminó correctamente' : `Proceso falló (exit=${exitCode})`;
        if (exitCode === 0) verificaciones.push({ titulo, detalle: text });
        else {
          fijos.push({ titulo, detalle: text, color: 'var(--danger)' });
          capturaPrimerError(titulo, text);
        }
        break;
      }
      case 'planner_fallback':
        // P7: el plan lo hizo el planner LOCAL (MockPlanner), no un LLM. Es
        // una etiqueta fija y siempre visible: el usuario no debe creer que un
        // modelo planificó su orden cuando no fue así.
        fijos.push({
          titulo: 'Plan local (MockPlanner)',
          detalle: 'No se usó un modelo LLM para planificar: lo hizo el planificador local del motor.',
          color: 'var(--warning)',
        });
        break;
      case 'governance_blocked_v1':
        capturaPrimerError('La política de coste bloqueó esta ejecución', String(p.reason ?? 'Solo gratis impide el modelo seleccionado.'));
        break;
      case 'native_tool_session_stopped_v1':
        fijos.push({
          titulo: 'La sesión de herramientas nativas se detuvo',
          detalle: String(p.reason ?? 'La ejecución fue detenida antes de completar las herramientas.'),
          color: 'var(--danger)',
        });
        break;
      case 'native_tool_session_failed_v1':
        fijos.push({
          titulo: 'La sesión de herramientas nativas falló',
          detalle: String(p.reason ?? 'La ejecución de herramientas no pudo completarse.'),
          color: 'var(--danger)',
        });
        break;
      case 'native_tool_result_v1': {
        const tool = String(p.tool_name ?? 'herramienta nativa');
        const task = String(p.task_id ?? '');
        const prefix = task ? `Tarea ${task}` : '';
        // D-C1 (E5.11): solo run_command devuelve exit_code. Las tools de
        // escritura/lectura/finish informan {ok, path, bytes, sha256} o
        // {error, detail} — un resultado sin exit_code NO es un fallo.
        if (typeof p.error === 'string' && p.error.length > 0) {
          fijos.push({
            // USUARIO-NUEVO R2 (10-nov): sin el código crudo; `detail` lo explica.
            titulo: `No se pudo usar ${tool}`,
            detalle: [prefix, String(p.detail ?? '')].filter(Boolean).join('  —  '),
            color: 'var(--danger)',
          });
          break;
        }
        if (typeof p.exit_code === 'number') {
          const exitCode = p.exit_code;
          const timedOut = p.timed_out === true;
          const output = [String(p.stdout ?? ''), String(p.stderr ?? '')].filter(Boolean).join('\n');
          const detail = [prefix, output].filter(Boolean).join('  —  ');
          if (exitCode === 0 && !timedOut) {
            verificaciones.push({ titulo: `${tool} terminó correctamente`, detalle: detail });
          } else {
            fijos.push({
              titulo: timedOut ? `${tool} superó el tiempo límite` : `${tool} terminó con código ${exitCode}`,
              detalle: detail,
              color: 'var(--danger)',
            });
          }
          break;
        }
        const bits: string[] = [prefix];
        if (typeof p.path === 'string' && p.path) bits.push(String(p.path));
        if (typeof p.bytes === 'number') bits.push(`${p.bytes} B`);
        if (typeof p.summary === 'string' && p.summary) bits.push(String(p.summary));
        verificaciones.push({
          titulo: p.finished === true ? `${tool}: sesión agéntica cerrada` : `${tool} completada`,
          detalle: bits.filter(Boolean).join('  —  '),
        });
        break;
      }
      case 'agentic_unavailable': {
        fijos.push({
          titulo: `Modo agéntico no disponible para ${String(p.model ?? 'el modelo asignado')}`,
          detalle: [String(p.task_id ? `Tarea ${String(p.task_id)}` : ''), String(p.reason ?? '')].filter(Boolean).join('  —  '),
          color: 'var(--warning)',
        });
        break;
      }
      case 'order_done':
        fijos.push({
          titulo: 'Orden completada',
          detalle: `${String(p.completed ?? 0)} tarea(s) completada(s), ${String(p.failed ?? 0)} fallida(s)`,
          color: 'var(--success)',
        });
        break;
      case 'order_failed':
        capturaPrimerError('La orden terminó con errores', String(p.cause ?? ''));
        break;
      default:
        break;
    }
  }

  return {
    fijos,
    olas,
    tareas,
    verificaciones,
    proveedores,
    fallbacks,
    proveedoresDistintos,
    proveedoresFallidos,
    primerError,
  };
}

/**
 * Fase terminal de la orden para la píldora de ACTIVIDAD, según su estado REAL.
 *
 * B2 (orden 159): el panel decía "done" porque solo miraba `dispatch.ok`, pero
 * el hilo de despacho termina "ok" incluso cuando la orden falló — el motor
 * responde ok del hilo aunque commitTerminal hubiera escrito `failed`. El
 * estado que manda es el que el motor sincronizó (DaOrderStatus: done=5,
 * failed=6, rejected=7, cancelled=9). `dispatchOk` solo decide cuando la
 * consulta del estado no llegó (null): peor un fallo que un falso "done".
 */
export function terminalOrderPhase(
  dispatchOk: boolean,
  orderStatus: number | null | undefined
): 'error' | 'done' | 'cancelled' | 'audit-unavailable' {
  if (orderStatus === 9) return 'cancelled';
  // AUDIT-UNAVAILABLE-P0 (DaOrderStatus 11): ni done ni error — la ejecución
  // terminó pero ninguna auditoría produjo veredicto usable. La píldora y la
  // fase muestran "Sin auditar" con reintento manual, no un genérico de fallo.
  if (orderStatus === 11) return 'audit-unavailable';
  if (orderStatus === 6 || orderStatus === 7) return 'error';
  return dispatchOk ? 'done' : 'error';
}

/** Nombre de archivo de una ruta, sin el directorio. */
function basename(path: string): string {
  const i = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  return i >= 0 ? path.slice(i + 1) : path;
}

/**
 * Dice QUÉ pasó de verdad en un intento de proveedor fallido, en vez de mentir.
 *
 * Hasta la orden 157 la tarjeta decía "no sirvió: empty" — y `empty` era
 * "el proveedor no respondió", cuando la respuesta real podía ser perfecta y
 * quien la tiraba era NUESTRO extractor (§1.1-quater de ESTADO-Y-PENDIENTES).
 * La traza ya llevaba desde la 148 los campos que lo desmienten: `total_len`
 * (cuántos caracteres SÍ llegaron), `closed` (si el JSON cerraba su
 * contenedor) y `error_name` (el error de Zig de este intento). Aquí se
 * construye el relato con esos tres + `status`, como pidió el usuario.
 */
export function describeProviderFailure(p: Record<string, unknown>): string {
  const status = String(p.status ?? '');
  const error_name = String(p.error_name ?? '');
  const total_len = Number(p.total_len ?? 0);
  const closed = p.closed;

  const partes: string[] = [];
  if (p.http_status != null) partes.push(`HTTP ${String(p.http_status)}`);
  if (p.reason) partes.push(String(p.reason));
  if (p.excerpt) partes.push(String(p.excerpt));

  // Con `total_len` la respuesta NO fue vacía: lo que falló fue aguas abajo.
  if (total_len > 0) {
    partes.push(`respondió ${total_len.toLocaleString('es-MX')} caracteres`);
    if (typeof closed === 'boolean') {
      partes.push(
        closed
          ? 'la respuesta cerró su contenedor JSON'
          : 'la respuesta quedó truncada (sin cierre JSON)'
      );
    } else {
      partes.push('pero el extractor no encontró JSON usable');
    }
  } else if (status === 'empty') {
    partes.push('no devolvió texto');
  } else {
    partes.push(`estado ${status || 'error desconocido'}`);
  }

  if (error_name && error_name !== 'empty') {
    partes.push(`error: ${error_name}`);
  }
  if (status === 'empty' && total_len === 0) {
    partes.push('parece un fallo real del proveedor, no del parser');
  }
  return partes.join('; ');
}

/**
 * Los fallos de una orden reducidos a líneas accionables, en orden.
 *
 * Un intento de proveedor fallido es un problema SOLO si no queda ninguno
 * que responda; de lo contrario es el fallback normal y el resumen de la
 * tarjeta ya lo cuenta. `order_failed`/`provider_contract_abort`/
 * `provider_exhausted` sí son terminales del fallo, y `task_failed` es la
 * causa de ejecución.
 */
export function synthProblems(events: OrderEvent[]): string[] {
  const problemas: string[] = [];
  let proveedoresFallidos = 0;
  let proveedoresOk = 0;
  for (const e of events) {
    const p = eventPayload(e);
    switch (String(e.kind || '')) {
      case 'order_failed':
        problemas.push(`La orden terminó con errores: ${String(p.reason ?? p.cause ?? 'consulta la traza')}.`);
        break;
      case 'provider_contract_abort':
        problemas.push(
          `Cadena detenida: ${String(p.providers_empty ?? 0)} proveedores respondieron sin JSON usable — es el contrato, no el proveedor.`
        );
        break;
      case 'provider_exhausted':
        problemas.push('Todos los proveedores fallaron: no quedó ningún LLM que responder.');
        break;
      case 'test_evidence_v1':
        if (p.ran !== true || Number(p.exit_code) !== 0 || p.timed_out === true) {
          problemas.push(`La prueba de ${String(p.producer_task_id ?? '')} no pasó: ${String(p.command ?? '')}${p.stderr ? ` — ${String(p.stderr)}` : ''}`);
        }
        break;
      case 'task_failed':
        problemas.push(
          `La tarea ${String(p.task_id ?? '')} falló en ejecución${p.cause ? `: ${String(p.cause)}` : ''}.`
        );
        break;
      case 'task_provider_failed':
        proveedoresFallidos += 1;
        break;
      case 'task_provider_ok':
        proveedoresOk += 1;
        break;
      default:
        break;
    }
  }
  // Resumen de intentos: solo merece línea propia si no hubo ni un solo ok.
  if (proveedoresOk === 0 && proveedoresFallidos > 0) {
    problemas.push(
      `Ningún proveedor completó una llamada (${proveedoresFallidos} intento(s) fallido(s)).`
    );
  }
  return problemas;
}
