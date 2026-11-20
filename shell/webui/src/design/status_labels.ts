/**
 * Una sola tabla de etiquetas en español para los estados que enseña la cabina.
 *
 * Antes cada panel traducía a su manera —o no traducía— y la interfaz mostraba
 * el valor crudo del motor (`done`, `failed`, `cancelled`, `awaiting-approval`…).
 * El valor INTERNO nunca cambia: esto solo se usa para pintar.
 *
 * Cubre los dos vocabularios que circulan por el puente:
 *
 *  - `DaOrderStatus` (core/src/c_api.zig:271) y su gemelo
 *    `superagent.OrderStatus` (core/src/superagent.zig:197): pending,
 *    clarifying, planned, approved, running, awaiting_approval, done, failed,
 *    rejected, cancelled, interrupted, audit_unavailable, awaiting_best_of_n.
 *    `da_sessions_json` (core/src/c_api.zig:6639) los emite como `status_text`
 *    con guion bajo, y como `status` numérico en el mismo orden del enum.
 *  - `Phase` de MissionControlPanel (shell/webui/src/panes/mission_control.ts:83):
 *    idle, planning, clarifying, chat, awaiting-approval, running, done,
 *    interrupted, audit-unavailable, best-of-n, error. Usa guion medio.
 *
 * De ahí que la búsqueda ignore el separador y las mayúsculas.
 */
const STATUS_LABELS: Record<string, string> = {
  // Órdenes (DaOrderStatus / superagent.OrderStatus).
  self_reviewed: 'Autorrevisada',
  pending: 'Pendiente',
  clarifying: 'Necesita aclaraciones',
  planned: 'Plan sin aprobar',
  approved: 'Aprobada',
  running: 'Ejecutando',
  awaiting_approval: 'Pendiente de aprobar',
  done: 'Hecha',
  failed: 'Fallida',
  rejected: 'Rechazada',
  cancelled: 'Cancelada',
  interrupted: 'Interrumpida',
  audit_unavailable: 'Sin auditar',
  awaiting_best_of_n: 'Eligiendo candidata',
  // Fases del centro de mando (Phase).
  planning: 'Planificando',
  chat: 'Conversación',
  best_of_n: 'Eligiendo candidata',
  'best-of-n': 'Eligiendo candidata',
  idle: 'Inactivo',
  error: 'Error',
};

/** Índice numérico de `DaOrderStatus` (mismo orden que el enum C). */
const ORDER_STATUS_BY_INT: string[] = [
  'pending',
  'clarifying',
  'planned',
  'approved',
  'running',
  'done',
  'failed',
  'rejected',
  'awaiting_approval',
  'cancelled',
  'interrupted',
  'audit_unavailable',
  'awaiting_best_of_n',
];

/**
 * Clave canónica (con guion bajo) de un estado de orden dado como texto o como
 * número del enum C, o '' si no se reconoce. La usa la bandeja de avisos
 * para no repetir esta tabla.
 */
export function orderStatusKey(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return '';
  const raw = String(value).trim();
  if (!raw) return '';
  if (/^\d+$/.test(raw)) return ORDER_STATUS_BY_INT[Number(raw)] ?? '';
  return raw.toLowerCase().replace(/-/g, '_');
}

/**
 * Traduce un estado (texto o número) a su etiqueta en español. Si no lo
 * reconoce devuelve el valor original tal cual — nunca inventa.
 */
export function statusLabel(value: string | number | null | undefined): string {
  if (value === null || value === undefined) return '';
  if (typeof value === 'number') {
    const key = ORDER_STATUS_BY_INT[value];
    return key ? STATUS_LABELS[key] : String(value);
  }
  const raw = String(value).trim();
  if (!raw) return '';
  if (/^\d+$/.test(raw)) {
    const key = ORDER_STATUS_BY_INT[Number(raw)];
    if (key) return STATUS_LABELS[key];
  }
  // Acepta `awaiting_approval` y `awaiting-approval` como el mismo estado.
  const key = raw.toLowerCase().replace(/-/g, '_');
  return STATUS_LABELS[key] ?? raw;
}

/**
 * Remate D1 (10-nov): ¿la vuelta delegó subtareas y no se integraron todas?
 * `delegated`/`integrated` los da `da_sessions_json` desde `delegation_finished_v1`.
 */
export function delegacionIncompleta(delegated: number | null | undefined, integrated: number | null | undefined): boolean {
  const n = Number(delegated ?? 0);
  return n > 0 && Number(integrated ?? 0) < n;
}

/**
 * Etiqueta de una sesión en la barra lateral. Una vuelta de «DevAgents» que
 * delegó lleva el recuento cuando no se integró todo («Sin auditar · 0 de 2
 * integradas»): antes salía «Hecha» en verde con 0 de 2.
 */
export function estadoDeSesion(
  value: string | number | null | undefined,
  delegated?: number | null,
  integrated?: number | null
): string {
  const base = statusLabel(value);
  if (!delegacionIncompleta(delegated, integrated)) return base;
  return `${base} · ${Number(integrated ?? 0)} de ${Number(delegated)} integradas`;
}

/** Departamentos reales (core/src/agent_def.zig:5) con su nombre en español. */
const DEPARTMENT_LABELS: Record<string, string> = {
  programacion: 'Programación',
  testing: 'Pruebas',
  auditoria: 'Auditoría',
  correccion: 'Corrección',
  documentacion: 'Documentación',
  diseno: 'Diseño',
};

/**
 * Traduce el `department`/`task_type` que persiste el motor a su nombre en
 * español. Los departamentos conocidos se traducen; cualquier otro valor se
 * devuelve intacto (el valor interno no se toca).
 */
export function departmentLabel(value: string | null | undefined): string {
  if (value === null || value === undefined) return '';
  const raw = String(value).trim();
  if (!raw) return '';
  return DEPARTMENT_LABELS[raw.toLowerCase()] ?? raw;
}
