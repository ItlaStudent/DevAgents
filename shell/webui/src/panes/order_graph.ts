import type { OrderEvent } from '../bridge/core_api';
import { eventPayload } from '../bridge/core_api';
import { html, joinHtml, SafeHtml } from '../design/html';

/**
 * (12-nov): la orden como grafo.
 *
 * Todo sale de los eventos del motor de esa orden, nunca del estado de la
 * cabina: `task_started` (modelo, skills, MCP), `provider_fallback` (qué modelo
 * sustituyó a cuál), `task_done` / `task_failed`, `task_audit*`,
 * `approval_needed` y `order_done` / `order_failed`.
 *
 * Colores: verde terminó (y su auditoría no la suspendió), rojo falló, amarillo
 * otro modelo sustituyó al elegido (y se dice cuál), azul en curso, gris en
 * espera. Opcional y apagado por defecto (decisión del propietario del 7-nov): sin
 * encender, la orden se resume en una tira de puntos.
 */

export type GraphState = 'done' | 'failed' | 'substituted' | 'running' | 'waiting' | 'skip';

export interface GraphNode {
  key: string;
  title: string;
  state: GraphState;
  detail: string;
}

export interface OrderGraph {
  /** Contexto, plan, tareas (en paralelo), auditoría y entrega, en este orden. */
  before: GraphNode[];
  tasks: GraphNode[];
  after: GraphNode[];
  /** Vista grande de la maqueta v2, página 3. */
  view: GraphView;
}

export const GRAPH_STORAGE_KEY = 'devagents.orderGraph.v1';

export const STATE_LABEL: Record<GraphState, string> = {
  done: 'Terminado',
  failed: 'Falló',
  substituted: 'Con sustituto',
  running: 'En curso',
  waiting: 'En espera',
  skip: 'Omitido',
};

const text = (value: unknown): string => (typeof value === 'string' ? value : value == null ? '' : String(value));
const list = (value: unknown): string[] => (Array.isArray(value) ? value.map(text).filter(Boolean) : []);
/** `task_audit` numera las tareas (1, 2…) y el resto las llama t1, t2… */
const taskKey = (value: unknown): string =>
  typeof value === 'number' ? `t${value}` : text(value);
const modelName = (provider: unknown, model: unknown): string =>
  [text(provider), text(model)].filter(Boolean).join(' / ');

interface TaskInfo {
  title: string;
  started: boolean;
  ended: '' | 'done' | 'failed';
  model: string;
  substitution: string;
  audit: '' | 'PASS' | 'FAIL';
  error: string;
  /** USUARIO-NUEVO B: subtarea delegada cancelada con «Detener». */
  cancelled: boolean;
}

export function buildOrderGraph(
  events: OrderEvent[],
  planned: Array<{ id: string; description?: string }> = [],
  options: { orderId?: number } = {},
): OrderGraph {
  const tasks = new Map<string, TaskInfo>();
  const task = (id: string, title = ''): TaskInfo => {
    let info = tasks.get(id);
    if (!info) {
      info = { title, started: false, ended: '', model: '', substitution: '', audit: '', error: '', cancelled: false };
      tasks.set(id, info);
    }
    if (!info.title && title) info.title = title;
    return info;
  };
  for (const p of planned) if (p.id) task(p.id, p.description ?? '');

  let running = false;
  let planSubstitution = '';
  let repoFiles: number | null = null;
  const skills = new Set<string>();
  const mcps = new Set<string>();
  let auditUnavailable = false;
  let delegating = false;
  let approvals = 0;
  let end: '' | 'done' | 'failed' = '';
  let endDetail = '';

  for (const e of events) {
    const p = eventPayload(e);
    const id = taskKey(p.task_id);
    switch (e.kind) {
      case 'order_running':
        running = true;
        break;
      case 'repo_map_built':
        if (typeof p.archivos === 'number') repoFiles = p.archivos;
        break;
      case 'task_started': {
        const t = task(id, text(p.description));
        t.started = true;
        t.model = modelName(p.provider, p.model);
        list(p.skills).forEach((s) => skills.add(s));
        list(p.mcps).forEach((m) => mcps.add(m));
        break;
      }
      case 'sidekick_task_v1': {
        if (id && text(p.model)) task(id).model = modelName(p.provider, p.model);
        break;
      }
      case 'provider_fallback': {
        const change = `${modelName(p.from_provider, p.from_model) || 'el modelo elegido'} → ${modelName(p.to_provider, p.to_model) || 'otro modelo'}`;
        if (id) task(id).substitution = change;
        else if (text(p.role) === 'planner') planSubstitution = change;
        break;
      }
      case 'task_done': {
        const t = task(id);
        t.ended = p.success === false ? 'failed' : 'done';
        if (text(p.model_used)) t.model = text(p.model_used);
        break;
      }
      case 'task_failed': {
        const t = task(id);
        t.ended = 'failed';
        t.error = text(p.error_msg) || text(p.cause);
        break;
      }
      case 'task_audit': {
        const verdict = text(p.verdict).toUpperCase();
        if (id && (verdict === 'PASS' || verdict === 'FAIL')) task(id).audit = verdict;
        break;
      }
      case 'audit_unavailable':
      case 'task_audit_unavailable_v1':
      case 'order_audit_unavailable_v1':
        auditUnavailable = true;
        break;
      case 'approval_needed':
        approvals += 1;
        break;
      // USUARIO-NUEVO B (10-nov): modo «DevAgents». Cada subtarea delegada es
      // una tarea del grafo, con lo que dicen SUS eventos en la conversación.
      case 'directo_started_v1':
        if (p.delegate === true) delegating = true;
        break;
      case 'delegation_started_v1':
        delegating = true;
        for (const s of Array.isArray(p.subtasks) ? (p.subtasks as Array<Record<string, unknown>>) : []) {
          const t = task(`d${text(s.index)}`, `${text(s.role)}: ${text(s.instruction)}`);
          t.started = !text(s.setup_error);
          if (text(s.setup_error)) {
            t.ended = 'failed';
            t.error = text(s.setup_error);
          }
          if (text(s.model)) t.model = text(s.model);
        }
        break;
      case 'delegation_subtask_finished_v1': {
        const t = task(`d${text(p.index)}`);
        t.started = true;
        const st = text(p.status);
        t.ended = st === 'done' ? 'done' : st === 'cancelled' ? '' : 'failed';
        if (st === 'cancelled') {
          t.cancelled = true;
          t.error = 'Cancelada con «Detener»: no se integró.';
        }
        if (text(p.model)) t.model = text(p.model);
        const verdict = text(p.verdict).toUpperCase();
        if (verdict === 'PASS' || verdict === 'FAIL') t.audit = verdict;
        else if (verdict === 'SIN AUDITAR' && st !== 'cancelled') auditUnavailable = true;
        if (text(p.error)) t.error = text(p.error);
        // Sin motivo de error (p. ej. «sin auditar»), la nota del motor dice
        // por qué no se integró.
        else if (st !== 'done' && st !== 'cancelled' && text(p.note)) t.error = text(p.note);
        break;
      }
      case 'order_done':
      case 'order_completed':
        end = 'done';
        break;
      case 'order_failed':
        end = 'failed';
        endDetail = text(p.reason);
        break;
      default:
        break;
    }
  }

  const taskNodes: GraphNode[] = [...tasks.entries()].map(([id, t]) => {
    let state: GraphState = t.started ? 'running' : 'waiting';
    if (t.ended === 'done') state = 'done';
    if (t.substitution && state !== 'waiting') state = 'substituted';
    if (t.ended === 'failed' || t.audit === 'FAIL') state = 'failed';
    // Una orden terminada no deja tareas «en curso».
    if (end && state === 'running') state = end === 'failed' ? 'failed' : 'done';
    if (t.cancelled) state = 'skip';
    const parts = [t.model ? `Modelo: ${t.model}` : ''];
    if (t.substitution) parts.push(`Sustituido: ${t.substitution}`);
    if (t.audit) parts.push(`Auditoría: ${t.audit}`);
    if (t.error) parts.push(t.error);
    return { key: id, title: t.title ? `${id} · ${t.title}` : id, state, detail: parts.filter(Boolean).join(' · ') };
  });

  const anyTask = taskNodes.length > 0;
  const contextParts = [
    repoFiles !== null ? `${repoFiles} archivos en el mapa del repositorio` : '',
    skills.size ? `Skills: ${[...skills].join(', ')}` : '',
    mcps.size ? `MCP: ${[...mcps].join(', ')}` : '',
  ].filter(Boolean);
  const before: GraphNode[] = [
    {
      key: 'context',
      title: 'Contexto',
      state: contextParts.length ? 'done' : running && !end && !anyTask ? 'running' : 'waiting',
      detail: contextParts.join(' · ') || 'Sin datos de contexto en los eventos de esta orden.',
    },
    delegating ? {
      // USUARIO-NUEVO B: en DevAgents no hay planificador; el modelo de la
      // conversación reparte. Se dibuja «omitido» y se dice por qué.
      key: 'plan',
      title: 'Plan',
      state: 'skip' as GraphState,
      detail: anyTask
        ? `Sin plan: el modelo de la conversación delegó ${taskNodes.length} subtarea(s) con delegate_tasks.`
        : 'Sin plan: en DevAgents el modelo conversa y delega si hace falta.',
    } : {
      key: 'plan',
      title: 'Plan',
      state: planSubstitution ? 'substituted' : anyTask ? 'done' : end === 'failed' ? 'failed' : running ? 'running' : 'waiting',
      detail: planSubstitution
        ? `Planificó un sustituto: ${planSubstitution}`
        : anyTask
          ? `${taskNodes.length} tarea(s)`
          : 'Aún sin tareas.',
    },
  ];

  const audited = taskNodes.filter((n) => tasks.get(n.key)?.audit);
  const auditFail = audited.some((n) => tasks.get(n.key)?.audit === 'FAIL');
  const after: GraphNode[] = [
    {
      key: 'audit',
      title: 'Auditoría',
      state: auditFail ? 'failed' : audited.length ? 'done' : auditUnavailable ? 'substituted' : 'waiting',
      detail: auditFail
        ? 'Alguna tarea no pasó la auditoría.'
        : audited.length
          ? `${audited.length} tarea(s) auditada(s) sin fallos.`
          : auditUnavailable
            ? 'Sin auditar: no había auditor independiente disponible.'
            : end
              ? 'Esta orden no pasó por auditoría.'
              : 'Pendiente.',
    },
    {
      key: 'delivery',
      title: 'Entrega',
      state: end === 'done' ? 'done' : end === 'failed' ? 'failed' : running || anyTask ? 'running' : 'waiting',
      detail:
        end === 'done'
          ? 'Orden terminada.'
          : end === 'failed'
            ? endDetail || 'La orden falló.'
            : approvals
              ? `Esperando ${approvals} aprobación(es).`
              : 'En curso.',
    },
  ];
  const base = { before, tasks: taskNodes, after };
  return { ...base, view: buildView(events, base, options.orderId ?? 0, delegating) };
}

// ---------------------------------------------------------------------------
// Vista grande (12-nov, sobre la maqueta v2, página 3): carriles Contexto,
// Plan, Tareas por rol, Auditoría y Cierre; nodo raíz; etiqueta de rol encima
// de cada nodo; la colmena como grupo; conectores curvos; leyenda y panel de
// detalle. Todo sale de los eventos; lo que el motor no emite se pinta como
// «omitido» y lo dice, nunca se inventa.

export interface ViewNode {
  key: string;
  title: string;
  sub: string;
  role: string;
  state: GraphState;
  detail: string;
  /** Tarea o entrega fallida: ofrece Reintentar, Cambiar modelo y Ver registro. */
  actions: boolean;
}

export interface GraphView {
  root: ViewNode;
  context: ViewNode[];
  plan: ViewNode;
  tasks: ViewNode[];
  /** Grupos de tareas que corrieron a la vez (índices en `tasks`). */
  groups: number[][];
  swarm: boolean;
  /** Siempre dos: el auditor y el segundo auditor (omitido si no lo hubo). */
  audits: ViewNode[];
  /** Auditor de cada tarea (índice en `audits`). */
  auditOf: Record<string, number>;
  /** Tareas que además revisó el segundo auditor (`task_audit` con auditor_index 2). */
  secondAudited: string[];
  /** Replanificaciones (`replan_v1`): el lazo del Plan a sí mismo. */
  replans: Array<{ reason: string; changes: string }>;
  /** Por qué no hay caja de colmena, si la orden pedía Colmena y el motor no registró olas. */
  hiveNote: string;
  verify: ViewNode;
  ship: ViewNode;
  mode: string;
  progress: string;
}

// T8: «SIDEKICK» ya no sale del tipo de tarea; solo de `sidekick_task_v1`,
// que el motor emite cuando el modelo de la tarea lo fijó el rol sidekick.
const ROLE_BY_TYPE: Record<string, string> = {
  programar: 'PROGRAMADOR',
  ejecutar: 'EJECUTOR',
  investigar: 'INVESTIGACIÓN',
  documentar: 'DOCUMENTACIÓN',
  resumir: 'RESUMEN',
  probar: 'VERIFICADOR',
  verificar: 'VERIFICADOR',
  revisar: 'REVISOR',
};

/** Motivo de `replan_v1` en palabras del usuario; uno desconocido se muestra tal cual (como texto). */
const REPLAN_REASON: Record<string, string> = {
  user_changes: 'cambios pedidos por el usuario',
  agent_follow_up: 'siguiente paso que pidió el agente',
};

/** «agent:claude-code» → «Claude Code (CLI)»; «nvidia/nemotron-x» → «nemotron-x». */
export function shortModel(provider: unknown, model: unknown): string {
  const prov = text(provider);
  const mod = text(model);
  if (prov.startsWith('agent:')) {
    const name = prov.slice(6).split(/[-_]/).map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w)).join(' ');
    return `${name} (CLI)`;
  }
  if (prov === 'deterministic-gate') return 'Puerta determinista';
  if (!mod || mod === 'default') return prov;
  return mod.split('/').pop() ?? mod;
}

function clock(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  // Una orden que esperó una aprobación días enteros no se cuenta en minutos.
  if (s >= 86400) return `${Math.floor(s / 86400)} d ${Math.floor((s % 86400) / 3600)} h`;
  if (s >= 3600) return `${Math.floor(s / 3600)} h ${Math.floor((s % 3600) / 60)} min`;
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

function buildView(events: OrderEvent[], graph: Omit<OrderGraph, 'view'>, orderId: number, delegating = false): GraphView {
  interface T { start: number; end: number; role: string; model: string; from: string; to: string; auditor: string }
  const info = new Map<string, T>();
  const t = (id: string): T => {
    let v = info.get(id);
    if (!v) info.set(id, (v = { start: 0, end: 0, role: '', model: '', from: '', to: '', auditor: '' }));
    return v;
  };
  let swarm = false;
  let repoFiles: number | null = null;
  let web = false;
  const skills = new Set<string>();
  const mcps = new Set<string>();
  let planModel = '';
  // T8: auditores por su índice real del motor. 0 = puerta
  // determinista y 1 = primer auditor van al nodo «Auditoría»; 2 = segundo
  // auditor. Órdenes anteriores sin `auditor_index`: todo al primero.
  const auditors: Array<{ names: string[]; verdicts: string[] }> = [{ names: [], verdicts: [] }, { names: [], verdicts: [] }];
  const secondAudited = new Set<string>();
  let lessons: { count: number; titles: string[] } | null = null;
  const savedLessons: string[] = [];
  const waveGroups: string[][] = [];
  const delegationGroups: string[][] = [];
  const replans: Array<{ reason: string; changes: string }> = [];
  const sidekicks = new Set<string>();
  const gates: Array<{ kind: string; failed: boolean }> = [];
  let ship: '' | 'running' | 'done' | 'failed' = '';
  let first = 0;
  let last = 0;
  for (const e of events) {
    const p = eventPayload(e);
    // El motor guarda unos eventos en segundos y otros en milisegundos.
    const raw = typeof e.ts === 'number' && e.ts > 0 ? e.ts : 0;
    const scaled = raw && raw < 1e11 ? raw * 1000 : raw;
    // Algunos eventos no traen una fecha real (0 o un contador): no cuentan para el tiempo.
    const ts = scaled >= 1e12 ? scaled : 0;
    if (ts) {
      if (!first || ts < first) first = ts;
      if (ts > last) last = ts;
    }
    const id = taskKey(p.task_id);
    switch (e.kind) {
      case 'composer_swarm_v1':
        // El evento guarda un booleano suelto: `true` o `false`.
        swarm = (e as { payload?: unknown }).payload === true || (e as { payload_json?: unknown }).payload_json === 'true' || p.enabled === true;
        break;
      case 'repo_map_built':
        if (typeof p.archivos === 'number') repoFiles = p.archivos;
        break;
      case 'web_search':
        web = true;
        break;
      case 'task_started': {
        const v = t(id);
        v.start = ts;
        const kind = text(p.task_type).toLowerCase();
        v.role = text(p.provider).startsWith('agent:') ? 'EJECUTOR' : ROLE_BY_TYPE[kind] ?? (text(p.department) || 'tarea').toUpperCase();
        v.model = shortModel(p.provider, p.model);
        list(p.skills).forEach((s) => skills.add(s));
        list(p.mcps).forEach((m) => mcps.add(m));
        break;
      }
      case 'provider_fallback':
        if (id) {
          const v = t(id);
          v.from = shortModel(p.from_provider, p.from_model);
          v.to = shortModel(p.to_provider, p.to_model);
          v.model = v.to;
        } else if (text(p.role) === 'planner') planModel = `${shortModel(p.from_provider, p.from_model)} → ${shortModel(p.to_provider, p.to_model)}`;
        break;
      case 'task_done':
      case 'task_failed': {
        const v = t(id);
        v.end = ts;
        if (text(p.model_used) && !v.to) v.model = shortModel(p.provider ?? '', p.model_used) || v.model;
        break;
      }
      case 'task_audit': {
        const name = shortModel(p.provider, p.model) || 'Auditor';
        const second = p.auditor_index === 2;
        const a = auditors[second ? 1 : 0];
        if (!a.names.includes(name)) a.names.push(name);
        a.verdicts.push(text(p.verdict).toUpperCase());
        if (id && second) secondAudited.add(id);
        else if (id) t(id).auditor = name;
        break;
      }
      case 'memory_lessons_v1': {
        // La última consulta manda (un replan vuelve a consultar).
        const count = typeof p.count === 'number' && p.count >= 0 ? Math.floor(p.count) : 0;
        lessons = { count, titles: list(p.titles).slice(0, 5).map((s) => cut(s, 80)) };
        break;
      }
      case 'memory_lesson_saved_v1':
        savedLessons.push(cut(text(p.title), 80));
        break;
      case 'swarm_group_v1': {
        const members = list(p.members);
        if (members.length > 1) waveGroups.push(members);
        break;
      }
      case 'replan_v1':
        replans.push({ reason: text(p.reason), changes: cut(text(p.changes), 512) });
        break;
      case 'sidekick_task_v1':
        if (id) {
          sidekicks.add(id);
          if (text(p.model)) t(id).model = shortModel(p.provider, p.model);
        }
        break;
      // USUARIO-NUEVO B: subtareas delegadas (instante, rol, modelo y veredicto
      // de su auditor, tal como los cuenta la conversación).
      case 'delegation_started_v1': {
        const members: string[] = [];
        for (const s of Array.isArray(p.subtasks) ? (p.subtasks as Array<Record<string, unknown>>) : []) {
          const v = t(`d${text(s.index)}`);
          v.start = ts;
          v.role = text(s.role).toUpperCase() || 'SUBTAREA';
          if (text(s.model)) v.model = shortModel('', s.model);
          if (!text(s.setup_error)) members.push(`d${text(s.index)}`);
        }
        // Las subtareas de un mismo reparto se lanzan juntas (dato del evento).
        if (members.length > 1) delegationGroups.push(members);
        break;
      }
      case 'delegation_subtask_finished_v1': {
        const v = t(`d${text(p.index)}`);
        v.end = ts;
        if (!v.role) v.role = text(p.role).toUpperCase() || 'SUBTAREA';
        if (text(p.model)) v.model = shortModel('', p.model);
        const verdict = text(p.verdict).toUpperCase();
        if (verdict === 'PASS' || verdict === 'FAIL') {
          const name = 'Auditores de las subtareas';
          const a = auditors[0];
          if (!a.names.includes(name)) a.names.push(name);
          a.verdicts.push(verdict);
          v.auditor = name;
        }
        break;
      }
      case 'semantic_gate_v1':
      case 'browser_gate_v1':
      case 'auto_verify_triggered':
        gates.push({
          kind: e.kind,
          failed: p.passed === false || p.ok === false || /fail|rechaz/i.test(text(p.verdict) + text(p.status)),
        });
        break;
      case 'ship_started':
        ship = 'running';
        break;
      case 'ship_done':
        ship = 'done';
        break;
      case 'ship_failed':
        ship = 'failed';
        break;
      default:
        break;
    }
  }
  const [contextNode, planNode] = graph.before;
  const [auditNode, deliveryNode] = graph.after;
  const ended = deliveryNode.state === 'done' || deliveryNode.state === 'failed';
  const anyStarted = [...info.values()].some((v) => v.start > 0);

  const tasks: ViewNode[] = graph.tasks.map((n) => {
    const v = info.get(n.key);
    const model = v?.model || '';
    const dur = v && v.start && v.end ? clock(v.end - v.start) : '';
    const sub =
      n.state === 'substituted' && v?.from
        ? `${v.from} → ${v.to}`
        : n.state === 'failed'
          ? [model, 'falló'].filter(Boolean).join(' · ')
          : n.state === 'running'
            ? [model, 'en curso'].filter(Boolean).join(' · ')
            : n.state === 'waiting'
              ? 'en espera'
              : [model, dur].filter(Boolean).join(' · ');
    // En el nodo, el título sin el identificador (t1 · …), como en la maqueta; el detalle lo conserva.
    const plain = n.title.replace(/^[^·]+ · /, '') || n.title;
    const role = sidekicks.has(n.key) ? 'SIDEKICK' : v?.role || 'TAREA';
    const sidekickNote = sidekicks.has(n.key) ? ' Tarea del rol sidekick del compositor; se muestra el modelo ejecutado.' : '';
    return { key: n.key, title: plain, sub, role, state: n.state, detail: `${n.title}. ${n.detail || 'Sin más datos en los eventos.'}${sidekickNote}`, actions: n.state === 'failed' };
  });

  // T8: la colmena sale de `swarm_group_v1` (cada ola real con
  // más de una tarea y sus miembros) o del reparto de `delegation_started_v1`.
  // Sin esos eventos no hay grupo: ya no se deduce de la cercanía de horas.
  const byStart = tasks
    .map((n, i) => ({ i, s: info.get(n.key)?.start || Number.MAX_SAFE_INTEGER }))
    .sort((a, b) => a.s - b.s || a.i - b.i)
    .map((o) => tasks[o.i]);
  const memberGroups: string[][] = [];
  const seen = new Set<string>();
  for (const g of [...waveGroups, ...delegationGroups]) {
    const present = g.filter((k) => !seen.has(k) && tasks.some((n) => n.key === k));
    if (present.length < 2) continue;
    present.forEach((k) => seen.add(k));
    memberGroups.push(present);
  }
  // Los miembros de un grupo van seguidos en la columna (su caja los envuelve).
  const groupOf = new Map<string, number>();
  memberGroups.forEach((g, gi) => g.forEach((k) => groupOf.set(k, gi)));
  const sortedTasks: ViewNode[] = [];
  const placed = new Set<number>();
  const groups: number[][] = memberGroups.map(() => []);
  for (const n of byStart) {
    const gi = groupOf.get(n.key);
    if (gi === undefined) {
      sortedTasks.push(n);
      continue;
    }
    if (placed.has(gi)) continue;
    placed.add(gi);
    for (const m of byStart.filter((x) => groupOf.get(x.key) === gi)) {
      groups[gi].push(sortedTasks.length);
      sortedTasks.push(m);
    }
  }
  groups.sort((a, b) => a[0] - b[0]);
  const hiveNote =
    swarm && !groups.length && (anyStarted || ended)
      ? 'La orden iba en modo Colmena, pero el motor no registró ninguna ola con tareas en paralelo (swarm_group_v1).'
      : '';

  const lessonParts = [
    lessons ? `${lessons.count} ${lessons.count === 1 ? 'lección consultada' : 'lecciones consultadas'}` : '',
    savedLessons.length ? `${savedLessons.length} guardada${savedLessons.length === 1 ? '' : 's'}` : '',
  ].filter(Boolean);
  const memoryNode: ViewNode = lessonParts.length
    ? {
        key: 'ctx-memory', title: 'Memoria', role: 'CONTEXTO', actions: false, state: 'done',
        sub: lessonParts.join(' · '),
        detail: [
          lessons
            ? lessons.titles.length
              ? `Lecciones de órdenes anteriores que el motor dio al planificador: ${lessons.titles.map((s) => `«${s}»`).join(', ')}${lessons.count > lessons.titles.length ? ` y ${lessons.count - lessons.titles.length} más` : ''}.`
              : `El motor consultó la memoria y no había lecciones (${lessons.count}).`
            : '',
          savedLessons.length ? `Lección guardada al terminar: ${savedLessons.map((s) => `«${s}»`).join(', ')}.` : '',
        ].filter(Boolean).join(' '),
      }
    : {
        key: 'ctx-memory', title: 'Memoria', sub: 'sin consulta', role: 'CONTEXTO', state: 'skip', actions: false,
        detail: 'Omitida: el motor no registró ninguna consulta de lecciones de memoria para esta orden (sin memoria activa, o una orden anterior a este registro).',
      };

  const context: ViewNode[] = [
    memoryNode,
    {
      key: 'ctx-search', title: 'Búsqueda', role: 'CONTEXTO', actions: false,
      sub: repoFiles !== null ? `${repoFiles} archivos · mapa del repo` : 'sin búsqueda',
      state: repoFiles !== null ? 'done' : 'skip',
      detail: repoFiles !== null ? `Mapa del repositorio con ${repoFiles} archivos para situar el trabajo.` : 'Esta orden no construyó mapa del repositorio.',
    },
    {
      key: 'ctx-skills', title: 'Skills y MCP', role: 'CONTEXTO', actions: false,
      sub: `${skills.size} skills · ${mcps.size} conectores`,
      state: anyStarted ? 'done' : contextNode.state === 'running' ? 'running' : 'waiting',
      detail: [skills.size ? `Skills: ${[...skills].join(', ')}` : 'Ninguna skill asignada.', mcps.size ? `MCP: ${[...mcps].join(', ')}` : 'Ningún conector MCP asignado.'].join(' '),
    },
    {
      key: 'ctx-web', title: 'Búsqueda web', role: 'CONTEXTO', actions: false,
      sub: web ? 'usada' : 'no hacía falta',
      state: web ? 'done' : anyStarted || ended ? 'skip' : 'waiting',
      detail: web ? 'El agente buscó en la web.' : 'Omitida: nadie la pidió en esta orden.',
    },
  ];

  const replanText = replans.map((r) => `${REPLAN_REASON[r.reason] ?? (r.reason || 'sin motivo')}${r.changes ? `: «${r.changes}»` : ''}`);
  const plan: ViewNode = {
    key: 'plan', title: 'Plan', role: 'PLANIFICADOR', actions: false, state: planNode.state,
    detail: replans.length ? `${planNode.detail} Replanificado ${replans.length} ${replans.length === 1 ? 'vez' : 'veces'} — ${replanText.join(' · ')}.` : planNode.detail,
    sub: [planModel, graph.tasks.length ? `${graph.tasks.length} tareas` : '', replans.length ? `replan ×${replans.length}` : ''].filter(Boolean).join(' · ') || 'sin tareas aún',
  };

  const auditorNode = (i: 0 | 1): ViewNode | null => {
    const a = auditors[i];
    if (!a.verdicts.length) return null;
    const fail = a.verdicts.includes('FAIL');
    return {
      key: `audit-${i}`, title: i ? 'Segunda auditoría' : 'Auditoría', role: i ? 'SEGUNDO AUDITOR' : 'AUDITOR', actions: false,
      state: fail ? 'failed' : 'done',
      sub: `${a.names.join(', ')} · ${fail ? 'pidió cambios' : 'PASS'}`,
      detail: `${a.verdicts.length} veredicto(s): ${a.verdicts.join(', ')}.`,
    };
  };
  const audits: ViewNode[] = [
    auditorNode(0) ?? {
      key: 'audit-0', title: 'Auditoría', role: 'AUDITOR', actions: false,
      state: auditNode.state === 'substituted' ? 'skip' : ended ? 'skip' : 'waiting',
      sub: auditNode.state === 'substituted' ? 'sin auditor independiente' : ended ? 'no hubo' : 'espera',
      detail: auditNode.detail,
    },
    auditorNode(1) ?? {
      key: 'audit-1', title: 'Segunda auditoría', role: 'SEGUNDO AUDITOR', actions: false,
      state: ended ? 'skip' : 'waiting',
      sub: ended ? 'no la hubo' : 'espera',
      detail: ended
        ? 'Omitida: el motor no registró veredictos del segundo auditor en esta orden.'
        : 'Solo aparece si el compositor pidió un segundo auditor y el motor registra su veredicto.',
    },
  ];
  const auditOf: Record<string, number> = {};
  sortedTasks.forEach((n) => (auditOf[n.key] = 0));

  const gateFail = gates.some((g) => g.failed);
  const verify: ViewNode = {
    key: 'verify', title: 'Verificación', role: 'MOTOR', actions: false,
    state: gates.length ? (gateFail ? 'failed' : 'done') : ended ? 'skip' : 'waiting',
    sub: gates.length ? `${gates.length} comprobación(es)` : ended ? 'sin comprobaciones' : 'gates · pruebas',
    detail: gates.length ? `Puertas y pruebas del motor: ${[...new Set(gates.map((g) => g.kind))].join(', ')}.` : 'Puertas deterministas y pruebas del resultado declarado.',
  };
  const shipNode: ViewNode = ship
    ? { key: 'ship', title: 'Entrega', role: '', actions: ship === 'failed', state: ship === 'done' ? 'done' : ship === 'failed' ? 'failed' : 'running', sub: ship === 'done' ? 'PR entregado' : ship === 'failed' ? 'PR falló' : 'entregando PR', detail: deliveryNode.detail }
    : { key: 'ship', title: 'Entrega', role: '', actions: deliveryNode.state === 'failed', state: ended ? deliveryNode.state : 'waiting', sub: deliveryNode.state === 'done' ? 'orden terminada' : deliveryNode.state === 'failed' ? 'orden fallida' : 'espera', detail: deliveryNode.detail };

  const finished = graph.tasks.filter((n) => n.state === 'done' || n.state === 'failed' || (n.state === 'substituted' && info.get(n.key)?.end)).length;
  const elapsed = first ? clock((ended ? last : Math.max(last, Date.now())) - first) : '';
  return {
    root: {
      key: 'root', title: orderId > 0 ? `Orden #${orderId}` : 'Orden', role: '', actions: false,
      state: ended ? deliveryNode.state : 'running',
      sub: `${delegating ? 'DevAgents' : swarm ? 'Colmena' : 'Orquestado'} · ${graph.tasks.length} ${delegating ? 'subtareas' : 'tareas'}`,
      detail: 'La instrucción del usuario, sus adjuntos y los modos con que se lanzó la orden.',
    },
    context, plan, tasks: sortedTasks, groups, swarm: swarm || (delegating && groups.length > 0), audits, auditOf, verify, ship: shipNode,
    secondAudited: sortedTasks.filter((n) => secondAudited.has(n.key)).map((n) => n.key),
    replans, hiveNote,
    mode: delegating ? 'DevAgents (Directo + delegación)' : swarm ? 'Orquestado + Colmena' : 'Orquestado',
    progress: [`${finished} de ${graph.tasks.length}`, elapsed].filter(Boolean).join(' · '),
  };
}

const ICON: Partial<Record<GraphState, string>> = {
  done: 'M-4.5 0.5 L-1.5 3.5 L4.5 -3',
  failed: 'M-3.5 -3.5 L3.5 3.5 M3.5 -3.5 L-3.5 3.5',
  substituted: 'M0 -4.5 L5 4 L-5 4 Z M0 -1.5 L0 1.2 M0 2.6 L0 2.8',
};

function cut(value: string, max: number): string {
  return value.length > max ? value.slice(0, Math.max(1, max - 1)) + '…' : value;
}

/** El grafo grande, en SVG, con su cabecera, leyenda y panel de detalle. */
export function orderGraphMarkup(graph: OrderGraph, selected = ''): SafeHtml {
  const v = graph.view;
  const H = 46;
  type Box = { n: ViewNode; x: number; y: number; w: number };
  const boxes: Box[] = [];
  const at = (n: ViewNode, x: number, y: number, w: number): Box => {
    const b = { n, x, y, w };
    boxes.push(b);
    return b;
  };
  // Columna de tareas: los grupos en paralelo, dentro de su caja.
  const inGroup = new Map<number, number>();
  v.groups.forEach((g, gi) => g.forEach((k) => inGroup.set(k, gi)));
  const taskBoxes: Box[] = [];
  const hives: Array<{ y: number; h: number; size: number }> = [];
  let y = 62;
  v.tasks.forEach((n, k) => {
    const gi = inGroup.get(k);
    const startsGroup = gi !== undefined && v.groups[gi][0] === k;
    if (startsGroup) y += 18;
    const grouped = gi !== undefined;
    // Dentro de la colmena el rol lo dice la caja; el de cada miembro, en el detalle.
    taskBoxes.push(at(grouped ? { ...n, role: '' } : n, grouped ? 582 : 566, y, grouped ? 144 : 176));
    const endsGroup = gi !== undefined && v.groups[gi][v.groups[gi].length - 1] === k;
    if (startsGroup) hives.push({ y: y - 26, h: 0, size: v.groups[gi].length });
    if (endsGroup) hives[hives.length - 1].h = y + H + 12 - hives[hives.length - 1].y;
    y += grouped ? 60 : 72;
    if (endsGroup) y += 14;
  });
  const height = Math.max(530, y + 24);
  const mid = Math.round(height / 2 - H / 2);
  // Pocas tareas: la columna se centra a la altura del plan, como en la maqueta.
  if (taskBoxes.length) {
    const top = Math.min(taskBoxes[0].y, ...hives.map((h) => h.y));
    const bottom = Math.max(...taskBoxes.map((b) => b.y + H), ...hives.map((h) => h.y + h.h));
    const shift = Math.max(0, Math.round(height / 2 - (top + bottom) / 2));
    taskBoxes.forEach((b) => (b.y += shift));
    hives.forEach((h) => (h.y += shift));
  }
  const root = at(v.root, 20, mid, 118);
  const ctx = v.context.map((n, i) => at(n, 180, mid + (i - 1.5) * 80, 150));
  const plan = at(v.plan, 372, mid, 150);
  const audits = v.audits.map((n, i) => at(n, 790, v.audits.length > 1 ? mid + (i ? 90 : -90) : mid, 160));
  const verify = at(v.verify, 992, mid, 130);
  const ship = at(v.ship, 1150, mid, 100);

  // Como en la maqueta: animado solo hacia lo que está en curso; verde hacia lo terminado.
  const edgeKind = (from: Box, to: Box): string =>
    to.n.state === 'running'
      ? 'live'
      : (to.n.state === 'done' || to.n.state === 'substituted') && from.n.state !== 'waiting'
        ? 'done'
        : '';
  const edges: SafeHtml[] = [];
  const edge = (a: Box, b: Box) => {
    const x1 = a.x + a.w, y1 = a.y + H / 2, x2 = b.x, y2 = b.y + H / 2, mx = (x1 + x2) / 2;
    edges.push(html`<path class="ograph__edge ${edgeKind(a, b)}" d="M${x1} ${y1} C${mx} ${y1} ${mx} ${y2} ${x2} ${y2}"/>`);
  };
  ctx.forEach((c) => (edge(root, c), edge(c, plan)));
  taskBoxes.forEach((tb) => (edge(plan, tb), edge(tb, audits[v.auditOf[tb.n.key] ?? 0] ?? audits[0])));
  if (!taskBoxes.length) edge(plan, audits[0]);
  // T8: lo que revisó el segundo auditor llega también a su nodo.
  if (audits[1]) taskBoxes.filter((tb) => v.secondAudited.includes(tb.n.key)).forEach((tb) => edge(tb, audits[1]));
  audits.forEach((a) => edge(a, verify));
  edge(verify, ship);
  // T8: lazo del Plan a sí mismo, uno por orden con `replan_v1`, con el motivo en el detalle.
  const loop = v.replans.length
    ? html`<path class="ograph__edge ograph__loop done" data-graph-loop="plan" d="M${plan.x + plan.w - 30} ${plan.y} C${plan.x + plan.w - 10} ${plan.y - 44} ${plan.x + 10} ${plan.y - 44} ${plan.x + 30} ${plan.y}"/><text class="ograph__role" x="${plan.x + plan.w / 2 - 34}" y="${plan.y - 38}">REPLAN ×${v.replans.length}</text>`
    : '';

  const lanes: Array<[number, string, number]> = [[166, 'CONTEXTO', 176], [358, 'PLAN', 178], [552, 'TAREAS POR ROL', 204], [776, 'AUDITORÍA', 190], [978, 'CIERRE', 290]];
  const nodeSvg = (b: Box) => {
    const chars = Math.floor((b.w - 34) / 6.4);
    const icon = ICON[b.n.state];
    return html`<g class="ograph__n${b.n.key === selected ? ' sel' : ''}" data-state="${b.n.state}" data-graph-node="${b.n.key}" tabindex="0" role="button" aria-label="${b.n.title}: ${STATE_LABEL[b.n.state]}">
      <rect class="ograph__box" x="${b.x}" y="${b.y}" width="${b.w}" height="${H}" rx="9"/>
      ${b.n.role ? html`<text class="ograph__role" x="${b.x + 10}" y="${b.y - 5}">${b.n.role}</text>` : ''}
      <text class="ograph__t" x="${b.x + 10}" y="${b.y + 19}">${cut(b.n.title, chars)}</text>
      <text class="ograph__s" x="${b.x + 10}" y="${b.y + 35}">${cut(b.n.sub, chars + 3)}</text>
      ${b.n.state === 'running' ? html`<circle class="ograph__ring" cx="${b.x + b.w - 14}" cy="${b.y + 14}" r="5"/>` : ''}
      ${icon ? html`<path class="ograph__ic" transform="translate(${b.x + b.w - 14} ${b.y + 14})" d="${icon}"/>` : ''}
    </g>`;
  };
  const info = (b: Box) =>
    html`<div class="ograph__info" data-info="${b.n.key}" ${b.n.key === selected ? '' : 'hidden'}>
      <b>${b.n.title}</b>${b.n.role ? ` · ${b.n.role.toLowerCase()}` : ''} · <span>${b.n.sub}</span> · ${STATE_LABEL[b.n.state]}<br>${b.n.detail}
      ${b.n.actions
        ? html`<div class="ograph__actions">
            <button class="btn btn--sm" type="button" data-graph-act="retry">Reintentar</button>
            <button class="btn btn--sm btn--ghost" type="button" data-graph-act="model">Cambiar modelo</button>
            <button class="btn btn--sm btn--ghost" type="button" data-graph-act="log">Ver registro</button>
          </div>`
        : ''}
    </div>`;
  const legend: Array<[GraphState, string]> = [['done', 'Completada'], ['running', 'En curso'], ['substituted', 'Cuota agotada · sustituido'], ['failed', 'Falló'], ['waiting', 'En espera'], ['skip', 'Omitido']];
  return html`<div class="ograph" data-order-graph>
      <header class="ograph__bar">
        <span class="ograph__dot" data-state="${v.root.state}"></span><b>${v.root.title}</b>
        <span class="ograph__sp"></span>
        <span class="ograph__pill">${v.mode}</span>
        <span class="ograph__pill" data-state="${v.root.state === 'running' ? 'running' : ''}">${v.progress}</span>
        <button class="ograph__sw" type="button" role="switch" aria-checked="true" data-graph-act="hide" title="Ocultar grafo"><span class="ograph__tr"></span><span>Grafo</span></button>
      </header>
      <div class="ograph__canvas">
        <svg class="ograph__svg" viewBox="0 0 1270 ${height}" role="img" aria-label="Grafo de la orden">
          ${joinHtml(lanes.map(([x, title, w]) => html`<rect class="ograph__lane" x="${x}" y="8" width="${w}" height="${height - 16}" rx="10"/><text class="ograph__lanet" x="${x + 10}" y="24">${title}</text>`))}
          ${joinHtml(hives.map((h) => html`<rect class="ograph__hive" x="570" y="${h.y}" width="168" height="${h.h}" rx="12"/><text class="ograph__role ograph__hivet" x="580" y="${h.y + 14}">${v.swarm ? 'COLMENA · ' : ''}${h.size} EN PARALELO</text>`))}
          ${v.hiveNote ? html`<text class="ograph__role ograph__hivet" data-graph-hive="skip" x="562" y="40"><title>${v.hiveNote}</title>COLMENA · OMITIDA</text>` : ''}
          ${joinHtml(edges)}
          ${loop}
          ${joinHtml(boxes.map(nodeSvg))}
        </svg>
      </div>
      <div class="ograph__legend">${joinHtml(legend.map(([s, label]) => html`<span><i class="ograph__dot" data-state="${s}"></i>${label}</span>`))}</div>
      <div class="ograph__detail">
        <div class="ograph__info" data-info="" ${selected && boxes.some((b) => b.n.key === selected) ? 'hidden' : ''}>Pulsa un nodo para ver su rol, su modelo, el tiempo y el registro.</div>
        ${joinHtml(boxes.map(info))}
      </div>
    </div>`;
}

/** Apagado: una tira de puntos con el mismo color por nodo. */
export function orderDotsMarkup(graph: OrderGraph): SafeHtml {
  const nodes = [...graph.before, ...graph.tasks, ...graph.after];
  return html`<div class="ograph-dots" data-order-graph-dots>
      ${joinHtml(nodes.map((n) => html`<span class="ograph__dot" data-state="${n.state}" title="${n.title}: ${STATE_LABEL[n.state]}"></span>`))}
      <button class="btn btn--sm btn--ghost" type="button" data-graph-act="show">Ver como grafo</button>
    </div>`;
}

export function graphEnabled(): boolean {
  try {
    return window.localStorage.getItem(GRAPH_STORAGE_KEY) === '1';
  } catch {
    // Sin almacenamiento (bloqueado o privado) se queda en su valor por defecto: apagado.
    return false;
  }
}

export function setGraphEnabled(on: boolean): void {
  try {
    window.localStorage.setItem(GRAPH_STORAGE_KEY, on ? '1' : '0');
  } catch {
    // Preferencia de comodidad: sin almacenamiento dura lo que la sesión.
    sessionFallback = on;
  }
}

let sessionFallback: boolean | null = null;
export function graphEnabledNow(): boolean {
  // C · Centro de mando: el grafo siempre está encendido.
  if (typeof document !== 'undefined' && document.documentElement?.dataset?.centro === '1') return true;
  return sessionFallback ?? graphEnabled();
}
