import { icons } from '../design/icons';
import { fileIcon } from '../design/file_icons';
import { escapeAttribute as escAttr, escapeText as esc } from '../design/html';
import { notice } from '../design/notice';
import { OrderEvent, eventPayload } from '../bridge/core_api';
import { EVENTO_USO_CONTEXTO, colorContexto, nivelContexto } from './context_usage';

/**
 * r3: cinco ventanas flotantes sobre el lienzo del chat, con
 * desplazamiento independiente y plegado persistido. La fila superior abre
 * paneles opcionales; Actividad pertenece a su propio host fuera de la pila.
 * Cada cabecera plegada resume proyecto, contexto, archivos, cambios o tareas.
 *
 * Lo que se muestra es MEDIDO, no maquetado:
 *  - Entorno se relee al cambiar de proyecto, al terminar cada orden,
 *    al recuperar el foco y con un intervalo prudente solo mientras es visible.
 *  - Contexto = prompt_tokens de la ultima llamada medida de la conversacion
 *    activa / ventana de contexto del modelo (core.usage + core.providers.list);
 *    sin uso medido se dice «estimado» y por que.
 *  - Resultados son los archivos de la CONVERSACION activa (todas sus ordenes).
 *  - Cambios nunca cuenta `devagents-workspace/` (carpeta interna del motor).
 *  - Tareas incluye ordenes en curso de CUALQUIER conversacion.
 *
 * Frontera: este componente solo LEE estado salvo el commit LOCAL (modal +
 * consentimiento nativo del host, nunca push) y la cancelacion de ordenes
 * (confirmacion previa). Publica devagents:open-file y
 * devagents:settings-section, que ya tenia la cabina.
 */

export interface RightCardsGitFile {
  path: string;
  added: number;
  removed: number;
  untracked: boolean;
}

/** Sesion tal y como la lista el motor (da_sessions_json). */
export interface RightCardsSession {
  id?: number;
  order_id?: number;
  conversation_id?: string | null;
  title?: string;
  status?: string | number;
  status_text?: string;
  created_at?: number;
}

/** Consumo medido de una orden (core.usage). */
export interface RightCardsUsage {
  last_prompt?: number;
  last_provider?: string;
  last_model?: string;
  total_prompt?: number;
}

type ProviderRows = Array<{ name: string; models?: Array<{ name?: string; context_window?: number | null }> }>;

/** Lo que necesita del motor; el stub de las pruebas implementa lo mismo. */
export interface RightCardsCore {
  listDir(path?: string): Promise<{ root?: string; entries?: Array<{ name: string; path: string; isDir: boolean }> }>;
  gitBranch(root?: string): Promise<{ root?: string; isRepo?: boolean; branch?: string; ahead?: number; behind?: number }>;
  gitStatus(root?: string): Promise<{
    root?: string;
    isRepo?: boolean;
    branch?: string;
    added?: number;
    removed?: number;
    truncated?: boolean;
    files?: Array<Partial<RightCardsGitFile>>;
  }>;
  gitCommit(request: {
    root?: string;
    message: string;
    files: string[];
  }): Promise<{ root?: string; hash?: string; files?: string[] }>;
  remoteStatus(): Promise<{ running: boolean; url: string; pid: number }>;
  listArtifacts(orderId: number): Promise<Array<{ file_path?: string; file_name?: string; size?: number }>>;
  cancelOrder(orderId: number): Promise<{ cancelled: boolean }>;
  /** Opcionales: sin ellos la conversacion se reduce a la orden activa y el
   *  contexto cae a la estimacion por caracteres. */
  listSessions?(mode?: 'active' | 'archived' | 'all'): Promise<RightCardsSession[]>;
  usageSummary?(orderId: number): Promise<RightCardsUsage>;
  listProviders?(): Promise<ProviderRows>;
}

/** Vistas y controles existentes que alterna la fila de iconos. */
export interface RightCardsActions {
  /** Misma medición que Entorno, sin otra consulta a la raíz. */
  onEnvironment?: (project: string, root: string) => void;
  changeWorkspace?: () => void;
  togglePanel: () => void;
  toggleTerminal: () => void;
  toggleBrowser: () => void;
  toggleActivity?: () => void;
  showExplorer: () => void;
  showMenu: () => void;
  activeOrderId: () => number;
}

export interface RightCardsOptions {
  /** Intervalo de relectura de Entorno/Cambios/Tareas (solo con la columna visible). */
  pollMs?: number;
}

type RcCard = 'entorno' | 'contexto' | 'resultados' | 'cambios' | 'tareas';
const CARDS: RcCard[] = ['entorno', 'contexto', 'resultados', 'cambios', 'tareas'];
const TITLES: Record<RcCard, string> = {
  entorno: 'Entorno',
  contexto: 'Contexto',
  resultados: 'Resultados',
  cambios: 'Cambios',
  tareas: 'Tareas en segundo plano',
};

interface ThreadUsageDetail {
  chars?: number;
  tokens?: number;
  pct?: number | null;
  turns?: number;
}

interface TerminalStateDetail {
  running?: boolean;
  terminalId?: number;
  startedAt?: number;
}

type TaskStatus = 'running' | 'done' | 'failed' | 'blocked' | 'cancelled';

interface BackgroundTask {
  id: string;
  label: string;
  startedAt: number;
  finishedAt: number;
  status: TaskStatus;
  /** Orden del motor (cualquier conversacion) frente a subtarea de una orden. */
  orderId: number;
}

interface MeasuredContext {
  tokens: number;
  provider: string;
  model: string;
  window: number;
}

/** Clave propia: 'devagents.panel.right' gobierna el plegado de la COLUMNA
 *  entera (layout.ts) y no se toca desde aqui. */
const FOLD_KEY = 'devagents.panel.right.cards';
const VISIBLE_FILES = 5;
const MAX_FILES = 200;
const DEFAULT_POLL_MS = 15000;
const ORDERS_POLL_EVERY_TICKS = 5;
/** Carpeta interna del motor: nunca es trabajo del usuario. */
const INTERNAL_DIR = 'devagents-workspace';

/** Ventana asumida solo para la ESTIMACION por caracteres (auto_compact.ts). */
const ESTIMATE_WINDOW = 32768;

/** `121200` -> `121,2k`; `1000000` -> `1M`. Un solo sitio para las cifras. */
export function formatTokens(value: number): string {
  const n = Math.max(0, Math.round(Number(value) || 0));
  const trim = (x: number): string => x.toFixed(1).replace(/\.0$/, '').replace('.', ',');
  if (n >= 1_000_000) return `${trim(n / 1_000_000)}M`;
  if (n >= 1000) return `${trim(n / 1000)}k`;
  return String(n);
}

/** ¿Es una ruta de git dentro de la carpeta interna del motor? */
export function isEngineInternalPath(path: string): boolean {
  const parts = String(path || '').replace(/\\/g, '/').split('/');
  return !parts.some(part => part === '.' || part === '..') && parts[0].toLowerCase() === INTERNAL_DIR;
}

export class RightCardsPanel {
  private folded: Record<RcCard, boolean> = {
    entorno: false,
    contexto: false,
    resultados: false,
    cambios: false,
    tareas: false,
  };
  // Entorno
  private envLoaded = false;
  private project = '';
  private parent = '';
  private root = '';
  private isRepo = true;
  private branch = '';
  private ahead = 0;
  private behind = 0;
  private remoteOn: boolean | null = null;
  // Resultados (por conversacion)
  private filesByOrder = new Map<number, string[]>();
  private convOrderIds: number[] = [];
  private convKey = '';
  private lastOrderId = -1;
  private convEpoch = 0;
  private artifactsLoaded = new Set<number>();
  private showAllFiles = false;
  // Cambios
  private changes: RightCardsGitFile[] = [];
  private changesRepo = true;
  private changesAdded = 0;
  private changesRemoved = 0;
  private changesTruncated = false;
  private changesLoaded = false;
  private changesError = '';
  private changesShowAll = false;
  private confirmBusy = false;
  // Contexto
  private contextPct: number | null = null;
  private contextTokens = 0;
  private contextChars = 0;
  private measured: MeasuredContext | null = null;
  private providerCache: { at: number; rows: ProviderRows } | null = null;
  private contextEpoch = 0;
  // Terminal y tareas
  private terminalRunning = false;
  private terminalId = 0;
  private terminalStartedAt = 0;
  private terminalVisible = false;
  private runningTasks = new Map<string, BackgroundTask>();
  private runningOrders = new Map<number, BackgroundTask>();
  private finishedTasks: BackgroundTask[] = [];
  private finishedIds = new Set<string>();
  private tasksTick: number | null = null;
  private tickCount = 0;
  private tasksShowFinished = false;
  private cancelBusy = false;
  // Ciclo de vida
  private pollTimer: number | null = null;
  private destroyed = false;
  private readonly pollMs: number;

  private readonly onThreadUsage = (event: Event): void => {
    if (this.destroyed) return;
    const detail = (event as CustomEvent<ThreadUsageDetail>).detail;
    const raw = detail && typeof detail.pct === 'number' && Number.isFinite(detail.pct) ? detail.pct : null;
    this.contextPct = raw === null ? null : Math.min(100, Math.max(0, Math.round(raw)));
    this.contextTokens =
      detail && Number.isFinite(Number(detail.tokens)) ? Math.max(0, Number(detail.tokens)) : 0;
    this.contextChars =
      detail && Number.isFinite(Number(detail.chars)) ? Math.max(0, Number(detail.chars)) : 0;
    this.paintContext();
    this.paintSummaries();
    // El hilo se repinta al abrir sesion o empezar conversacion nueva: es la
    // senal mas fiable de que la orden activa pudo cambiar.
    void this.syncConversation();
  };

  private readonly onTerminalState = (event: Event): void => {
    if (this.destroyed) return;
    const detail = (event as CustomEvent<TerminalStateDetail>).detail || {};
    this.terminalRunning = detail.running === true;
    this.terminalId = this.terminalRunning ? Math.max(0, Number(detail.terminalId) || 0) : 0;
    this.terminalStartedAt = this.terminalRunning ? Number(detail.startedAt) || Date.now() : 0;
    this.paintTasks();
  };

  private readonly onWake = (): void => {
    if (this.destroyed || !this.isVisible()) return;
    this.refreshAll();
  };

  private readonly onVisibility = (): void => {
    if (document.visibilityState === 'visible') this.onWake();
  };

  private readonly onWorkspaceChanged = (): void => {
    if (this.destroyed) return;
    this.refreshAll();
  };

  /** r4-4: la fila de iconos y las ventanas existen SOLO en la vista
   * «Agente». Al salir, el host entero desaparece (dataset + clase del chat);
   * al re-entrar vuelve en su estado y se relee todo lo medible para no
   * pintar datos congelados. */
  private viewVisible = true;

  private readonly onViewChanged = (event: Event): void => {
    if (this.destroyed) return;
    const detail = (event as CustomEvent<unknown>).detail;
    this.setViewVisible(String(detail || 'agent') === 'agent');
  };

  /** Muestra u oculta fila de iconos y ventanas segun la vista activa. */
  public setViewVisible(visible: boolean): void {
    const wanted = visible && !this.destroyed;
    const returning = wanted && !this.viewVisible;
    this.viewVisible = wanted;
    this.host.dataset.viewHidden = wanted ? 'false' : 'true';
    document.getElementById('central-container')?.classList.toggle('cards-view-hidden', !wanted);
    if (returning) this.refreshAll();
  }

  constructor(
    private host: HTMLElement,
    private core: RightCardsCore,
    private actions: RightCardsActions,
    options: RightCardsOptions = {}
  ) {
    this.pollMs = options.pollMs && options.pollMs > 0 ? options.pollMs : DEFAULT_POLL_MS;
    this.folded = this.readFold();
    this.host.classList.add('right-cards-host');
    this.host.addEventListener('click', (e) => this.handleClick(e));
    document.addEventListener(EVENTO_USO_CONTEXTO, this.onThreadUsage);
    document.addEventListener('devagents:terminal-state', this.onTerminalState);
    document.addEventListener('devagents:workspace-changed', this.onWorkspaceChanged);
    document.addEventListener('devagents:view-changed', this.onViewChanged);
    document.addEventListener('visibilitychange', this.onVisibility);
    window.addEventListener('focus', this.onWake);
    this.renderShell();
    document.dispatchEvent(new CustomEvent('devagents:terminal-state-request'));
    // El hilo ya puede estar abierto cuando esta ventana se monta (main.ts
    // crea MissionControlPanel antes): se pide el uso vigente para no perder
    // el evento publicado antes de registrar el listener.
    document.dispatchEvent(new CustomEvent('devagents:thread-usage-request'));
    this.pollTimer = window.setInterval(() => this.autoTick(), this.pollMs) as unknown as number;
    void this.refreshEnvironment().then(() => this.refreshChanges());
    void this.syncConversation(true);
    void this.refreshOrders();
  }

  public destroy(): void {
    this.destroyed = true;
    this.stopTasksTick();
    if (this.pollTimer !== null) window.clearInterval(this.pollTimer);
    this.pollTimer = null;
    document.removeEventListener(EVENTO_USO_CONTEXTO, this.onThreadUsage);
    document.removeEventListener('devagents:terminal-state', this.onTerminalState);
    document.removeEventListener('devagents:workspace-changed', this.onWorkspaceChanged);
    document.removeEventListener('devagents:view-changed', this.onViewChanged);
    document.removeEventListener('visibilitychange', this.onVisibility);
    window.removeEventListener('focus', this.onWake);
    this.host.querySelector('[data-rc-modal]')?.remove();
    this.host.querySelector('[data-rc-task-modal]')?.remove();
  }

  /** Estado visible de la Terminal (el icono de la fila la abre y la cierra). */
  public setTerminalVisible(visible: boolean): void {
    this.terminalVisible = visible;
    const button = this.host.querySelector<HTMLElement>('.rc-tool[data-rc-action="terminal"]');
    if (button) button.setAttribute('aria-pressed', String(visible));
  }

  /** ¿La columna esta a la vista (no plegada ni la pestana oculta)? */
  private isVisible(): boolean {
    if (this.destroyed) return false;
    if (document.visibilityState === 'hidden') return false;
    const column = this.host;
    if (column && column.dataset.collapsed === 'true') return false;
    return this.host.getClientRects().length > 0;
  }

  /** Relectura de todo lo medible (foco, cambio de proyecto, fin de orden). */
  public refreshAll(): void {
    void this.refreshEnvironment();
    void this.refreshChanges();
    void this.syncConversation(true);
    void this.refreshOrders();
  }

  /** vueltas del sondeo desde la última lectura de Cambios. */
  private changesTicks = 0;

  private autoTick(): void {
    if (!this.isVisible()) return;
    void this.refreshEnvironment();
    // (8-nov): `core.git.status` valida el árbol entero del
    // proyecto en la única cola del puente (~4 s con 26 000 entradas), así
    // que cada sondeo congelaba la cabina. Cambios se relee al terminar una
    // orden, al volver el foco y con su botón; el sondeo, cada 4 vueltas.
    this.changesTicks += 1;
    if (this.changesTicks >= 4) {
      this.changesTicks = 0;
      void this.refreshChanges();
    }
    void this.refreshOrders();
  }

  // ---------------------------------------------------------------- Eventos --

  /**
   * Los eventos file_written que ya recolecta el panel de Actividad llegan
   * aqui por el mismo canal (onActivity de main.ts). Se resuelven con la misma
   * cascada de nombres que chat_panel.ts porque el payload real del motor
   * varia segun el tipo de tarea. Al cerrar una orden se releen Entorno,
   * Cambios, Contexto y Tareas.
   */
  public appendEvents(events: OrderEvent[]): void {
    let filesChanged = false;
    let orderEnded = false;
    const tasksChanged = this.absorbTasks(events);
    const orderId = Number(this.actions.activeOrderId()) || 0;
    for (const ev of events || []) {
      const kind = String(ev?.kind ?? '');
      if (kind === 'order_done' || kind === 'order_failed' || kind === 'order_cancelled') orderEnded = true;
      if (kind === 'external_agent_finished') this.absorbExternalUsage(eventPayload(ev));
      if (kind !== 'file_written') continue;
      const payload = eventPayload(ev);
      const raw =
        payload.file_path ?? payload.path ?? payload.file ?? payload.artifact_name ??
        payload.artifact ?? payload.output_path ?? '';
      const path = typeof raw === 'string' ? raw.trim() : '';
      if (!path || !(orderId > 0)) continue;
      filesChanged = this.addFile(orderId, path) || filesChanged;
    }
    if (orderId > 0 && !this.convOrderIds.includes(orderId)) {
      this.convOrderIds = [...this.convOrderIds, orderId].sort((a, b) => a - b);
    }
    if (filesChanged) this.paintResults();
    if (tasksChanged) this.paintTasks();
    if (orderEnded) {
      void this.refreshChanges();
      void this.refreshEnvironment();
      void this.syncConversation(true);
      void this.refreshOrders();
    }
  }

  private addFile(orderId: number, path: string): boolean {
    const list = this.filesByOrder.get(orderId) ?? [];
    if (list.includes(path)) return false;
    list.push(path);
    if (list.length > MAX_FILES) list.shift();
    this.filesByOrder.set(orderId, list);
    return true;
  }

  private absorbTasks(events: OrderEvent[]): boolean {
    let changed = false;
    for (const ev of events || []) {
      const kind = String(ev?.kind ?? '');
      const payload = eventPayload(ev);
      const id = String(payload.task_id ?? payload.task ?? payload.worker_id ?? '').trim();
      const ts = Number(ev?.ts) || Date.now();
      if (id && kind === 'task_started') {
        if (this.finishedIds.has(id) || this.runningTasks.has(id)) continue;
        const label =
          String(payload.description ?? payload.department ?? payload.task_type ?? id).trim() || id;
        this.runningTasks.set(id, { id, label, startedAt: ts, finishedAt: 0, status: 'running', orderId: 0 });
        changed = true;
        continue;
      }
      const status: TaskStatus | null =
        kind === 'task_done'
          ? 'done'
          : kind === 'task_failed'
            ? 'failed'
            : kind === 'task_blocked' || kind === 'task_audit_unavailable_v1'
              ? 'blocked'
              : null;
      if (id && status) {
        const label = String(payload.description ?? payload.department ?? payload.task_type ?? '').trim();
        changed = this.finishTask(id, status, ts, label) || changed;
        continue;
      }
      if (kind === 'order_done' || kind === 'order_failed' || kind === 'order_cancelled') {
        const final: TaskStatus =
          kind === 'order_done' ? 'done' : kind === 'order_cancelled' ? 'cancelled' : 'failed';
        for (const taskId of Array.from(this.runningTasks.keys())) {
          changed = this.finishTask(taskId, final, ts) || changed;
        }
      }
    }
    return changed;
  }

  private finishTask(id: string, status: TaskStatus, ts: number, label = ''): boolean {
    if (this.finishedIds.has(id)) return false;
    const task = this.runningTasks.get(id) || {
      id,
      label: label || id,
      startedAt: ts || Date.now(),
      finishedAt: 0,
      status: 'running' as TaskStatus,
      orderId: 0,
    };
    this.runningTasks.delete(id);
    this.finishedIds.add(id);
    this.finishedTasks.unshift({ ...task, status, finishedAt: ts || Date.now() });
    return true;
  }

  // ----------------------------------------------- Conversacion y Resultados --

  /**
   * La conversacion activa = la orden que tiene cargada el centro de mando y
   * todas las ordenes de su mismo `conversation_id` (el motor las agrupa por
   * hilo). Sin orden activa («Nueva conversacion») no hay archivos ni uso.
   * `force` relee tambien cuando la orden activa no cambio.
   */
  public async syncConversation(force = false): Promise<void> {
    if (this.destroyed) return;
    const active = Number(this.actions.activeOrderId()) || 0;
    if (active === this.lastOrderId && !force) return;
    const orderChanged = active !== this.lastOrderId;
    this.lastOrderId = active;
    const epoch = ++this.convEpoch;
    if (!(active > 0)) {
      this.convKey = '';
      this.convOrderIds = [];
      this.measured = null;
      this.showAllFiles = false;
      this.paintResults();
      this.paintContext();
      this.paintSummaries();
      return;
    }
    let ids = [active];
    let key = this.convKey;
    let found = false;
    if (this.core.listSessions) {
      try {
        const rows = (await this.core.listSessions('all')) || [];
        const idOf = (r: RightCardsSession): number => Number(r.id ?? r.order_id ?? 0) || 0;
        const mine = rows.find((r) => idOf(r) === active);
        const cid = mine?.conversation_id ? String(mine.conversation_id) : '';
        if (mine) {
          found = true;
          key = cid ? `c:${cid}` : `o:${active}`;
          if (cid) ids = rows.filter((r) => r.conversation_id === cid).map(idOf).filter((n) => n > 0);
        }
      } catch (error) {
        console.error('[rightCards] core.sessions.list falló:', error);
      }
    }
    if (epoch !== this.convEpoch || this.destroyed) return;
    if (!found) {
      // La orden recien creada aun no esta en la lista: si ya habia una
      // conversacion abierta se sigue en ella; si no, nace una nueva.
      key = this.convKey !== '' ? this.convKey : `o:${active}`;
      ids = Array.from(new Set([...this.convOrderIds, active]));
    }
    if (!ids.includes(active)) ids.push(active);
    const sameConversation = key === this.convKey;
    this.convKey = key;
    this.convOrderIds = ids.sort((a, b) => a - b);
    if (!sameConversation && orderChanged) {
      this.measured = null;
      this.showAllFiles = false;
    }
    await this.loadArtifacts(this.convOrderIds, active);
    if (epoch !== this.convEpoch || this.destroyed) return;
    this.paintResults();
    void this.refreshContext();
  }

  /** Recupera lo escrito por cada orden de la conversacion (red de recuperacion). */
  private async loadArtifacts(ids: number[], active: number): Promise<void> {
    for (const id of ids) {
      if (id !== active && this.artifactsLoaded.has(id)) continue;
      try {
        const rows = await this.core.listArtifacts(id);
        for (const row of rows || []) {
          const path = String(row?.file_path ?? '').trim();
          if (path) this.addFile(id, path);
        }
        this.artifactsLoaded.add(id);
      } catch (error) {
        // Los eventos siguen siendo la fuente principal; esto solo recupera.
        console.error('[rightCards] core.artifacts.list falló:', error);
      }
    }
  }

  /** Compatibilidad con la v1: relee los artefactos de la orden activa. */
  public async refreshArtifacts(): Promise<void> {
    await this.syncConversation(true);
  }

  private conversationFiles(): string[] {
    const out: string[] = [];
    const seen = new Set<string>();
    for (const id of this.convOrderIds) {
      for (const path of this.filesByOrder.get(id) ?? []) {
        if (seen.has(path)) continue;
        seen.add(path);
        out.push(path);
      }
    }
    return out;
  }

  // ---------------------------------------------------------------- Entorno --

  public async refreshEnvironment(): Promise<void> {
    try {
      const dir = await this.core.listDir('');
      this.root = String(dir?.root || '');
      const normalized = this.root.replace(/[\\/]+$/, '');
      const separator = normalized.includes('\\') ? '\\' : '/';
      const parts = normalized.split(/[\\/]/).filter((p) => p.length > 0);
      this.project = parts.length > 0 ? String(parts[parts.length - 1]) : '';
      this.parent = parts.length > 1 ? parts.slice(0, -1).join(separator) + separator : '';
    } catch (error) {
      console.error('[rightCards] fs.list falló:', error);
      this.root = this.project = this.parent = '';
    }
    try {
      const git = await this.core.gitBranch(this.root);
      this.isRepo = git?.isRepo !== false;
      this.branch = String(git?.branch || '');
      // Ahead/behind solo si el host ya lo devuelve; nunca se inventa.
      this.ahead = Math.max(0, Number(git?.ahead) || 0);
      this.behind = Math.max(0, Number(git?.behind) || 0);
    } catch (error) {
      console.error('[rightCards] core.git.branch falló:', error);
      this.isRepo = true;
      this.branch = '';
    }
    try {
      const remote = await this.core.remoteStatus();
      this.remoteOn = !!remote?.running;
    } catch (error) {
      console.error('[rightCards] core.remote.status falló:', error);
      this.remoteOn = null;
    }
    this.envLoaded = true;
    if (this.destroyed) return;
    this.actions.onEnvironment?.(this.project, this.root);
    this.paintEnvironment();
    this.paintSummaries();
  }

  // ---------------------------------------------------------------- Cambios --

  /**
   * Estado del arbol de trabajo. Solo lectura; el host lo resuelve con git
   * domesticado y devuelve rutas RELATIVAS al repositorio. `devagents-workspace/`
   * se descarta aqui tambien (defensa en profundidad: el host ya la filtra) y,
   * si hubo algo que descartar, los totales se recalculan con lo que queda.
   */
  public async refreshChanges(): Promise<void> {
    try {
      const status = await this.core.gitStatus(this.root);
      this.changesRepo = status?.isRepo !== false;
      this.changesTruncated = status?.truncated === true;
      const files: RightCardsGitFile[] = [];
      let dropped = false;
      for (const row of status?.files || []) {
        const path = String(row?.path ?? '').trim();
        if (!path) continue;
        if (isEngineInternalPath(path)) {
          dropped = true;
          continue;
        }
        files.push({
          path,
          added: Math.max(0, Number(row?.added) || 0),
          removed: Math.max(0, Number(row?.removed) || 0),
          untracked: row?.untracked === true,
        });
      }
      this.changes = files;
      this.changesAdded = dropped
        ? files.reduce((n, f) => n + f.added, 0)
        : Math.max(0, Number(status?.added) || 0);
      this.changesRemoved = dropped
        ? files.reduce((n, f) => n + f.removed, 0)
        : Math.max(0, Number(status?.removed) || 0);
      this.changesError = '';
    } catch (error) {
      this.changesError = String((error as { message?: string })?.message || error);
      this.changes = [];
      this.changesAdded = 0;
      this.changesRemoved = 0;
      this.changesTruncated = false;
    }
    this.changesLoaded = true;
    if (this.destroyed) return;
    this.paintChanges();
    this.paintSummaries();
  }

  // --------------------------------------------------------------- Contexto --

  /** `external_agent_finished` ya trae prompt_tokens de la ultima llamada. */
  private absorbExternalUsage(payload: Record<string, unknown>): void {
    const tokens = Number(payload.prompt_tokens) || 0;
    if (!(tokens > 0)) return;
    const model = String(payload.model ?? payload.agent ?? '');
    const provider = String(payload.provider ?? '');
    void this.lookupWindow(provider, model).then((window) => {
      if (this.destroyed) return;
      this.measured = { tokens, provider, model, window };
      this.paintContext();
      this.paintSummaries();
    });
  }

  private async lookupWindow(provider: string, model: string): Promise<number> {
    if (!this.core.listProviders || !model) return 0;
    try {
      if (!this.providerCache || Date.now() - this.providerCache.at > 60000) {
        this.providerCache = { at: Date.now(), rows: (await this.core.listProviders()) || [] };
      }
      const rows = this.providerCache.rows;
      const lower = (v: unknown): string => String(v ?? '').toLowerCase();
      const pick = (list: ProviderRows): number => {
        for (const p of list) {
          const hit = (p.models || []).find((m) => lower(m.name) === lower(model));
          const win = Number(hit?.context_window) || 0;
          if (win > 0) return win;
        }
        return 0;
      };
      const exact = pick(rows.filter((p) => lower(p.name) === lower(provider)));
      return exact > 0 ? exact : pick(rows);
    } catch (error) {
      console.error('[rightCards] core.providers.list falló:', error);
      return 0;
    }
  }

  /** Uso REAL de la ultima llamada de la conversacion activa (core.usage). */
  public async refreshContext(): Promise<void> {
    if (!this.core.usageSummary || this.destroyed) return;
    const epoch = ++this.contextEpoch;
    const ids = [...this.convOrderIds].sort((a, b) => b - a).slice(0, 6);
    for (const id of ids) {
      try {
        const usage = await this.core.usageSummary(id);
        const tokens = Number(usage?.last_prompt) || 0;
        if (!(tokens > 0)) continue;
        const provider = String(usage?.last_provider ?? '');
        const model = String(usage?.last_model ?? '');
        const window = await this.lookupWindow(provider, model);
        if (epoch !== this.contextEpoch || this.destroyed) return;
        this.measured = { tokens, provider, model, window };
        this.paintContext();
        this.paintSummaries();
        return;
      } catch (error) {
        console.error('[rightCards] core.usage falló:', error);
      }
    }
  }

  // ------------------------------------------------------------------ Tareas --

  /** Ordenes en curso de CUALQUIER conversacion (core.sessions.list). */
  public async refreshOrders(): Promise<void> {
    if (!this.core.listSessions || this.destroyed) return;
    let rows: RightCardsSession[] = [];
    try {
      rows = (await this.core.listSessions('active')) || [];
    } catch (error) {
      console.error('[rightCards] core.sessions.list falló:', error);
      return;
    }
    const live = new Map<number, BackgroundTask>();
    const ended = new Map<number, string>();
    for (const row of rows) {
      const id = Number(row.id ?? row.order_id ?? 0) || 0;
      if (!(id > 0)) continue;
      const text = String(row.status_text ?? '').toLowerCase();
      const num = Number(row.status);
      const running = text === 'running' || text === 'approved' || (!text && (num === 4 || num === 3));
      if (running) {
        const previous = this.runningOrders.get(id);
        const created = Number(row.created_at) > 0 ? Number(row.created_at) * 1000 : Date.now();
        live.set(id, {
          id: `order-${id}`,
          label: `#${id} · ${String(row.title || '').trim() || 'Orden'}`,
          startedAt: previous ? previous.startedAt : created,
          finishedAt: 0,
          status: 'running',
          orderId: id,
        });
      } else {
        ended.set(id, text);
      }
    }
    let changed = live.size !== this.runningOrders.size;
    for (const [id, task] of this.runningOrders) {
      if (live.has(id)) continue;
      const text = ended.get(id) ?? '';
      const status: TaskStatus = text === 'failed' ? 'failed' : text === 'cancelled' ? 'cancelled' : 'done';
      if (!this.finishedIds.has(task.id)) {
        this.finishedIds.add(task.id);
        this.finishedTasks.unshift({ ...task, status, finishedAt: Date.now() });
      }
      changed = true;
    }
    this.runningOrders = live;
    if (changed || live.size > 0) this.paintTasks();
    else this.paintSummaries();
  }

  // ------------------------------------------------------------------ Plegado --

  private readFold(): Record<RcCard, boolean> {
    const empty = { entorno: false, contexto: false, resultados: false, cambios: false, tareas: false };
    try {
      const raw = localStorage.getItem(FOLD_KEY);
      if (!raw) return empty;
      const parsed = JSON.parse(raw) as Partial<Record<RcCard, unknown>>;
      const out = { ...empty };
      for (const card of CARDS) out[card] = parsed?.[card] === true;
      return out;
    } catch (error) {
      notice('No se pudo leer el plegado de las ventanas: ' + String(error), 'error');
      return empty;
    }
  }

  private writeFold(): void {
    try {
      localStorage.setItem(FOLD_KEY, JSON.stringify(this.folded));
    } catch (error) {
      notice('No se pudo guardar el plegado de las ventanas: ' + String(error), 'error');
    }
  }

  // ------------------------------------------------------------------- Render --

  private renderShell(): void {
    this.host.innerHTML = `
      <div class="rc-tools" role="toolbar" aria-label="Herramientas del chat">
        <button class="rc-tool" type="button" data-rc-action="panel" title="Mostrar u ocultar las ventanas" aria-label="Mostrar u ocultar las ventanas">${icons.sidebarRight(16)}</button>
        <button class="rc-tool" type="button" data-rc-action="terminal" title="Abrir o cerrar la terminal integrada" aria-label="Abrir o cerrar la terminal integrada" aria-pressed="${this.terminalVisible ? 'true' : 'false'}">${icons.terminal(16)}</button>
        <button class="rc-tool" type="button" data-rc-action="browser" title="Navegador integrado" aria-label="Navegador integrado">${icons.globe(16)}</button>
        <button class="rc-tool" type="button" data-rc-action="explorer" title="Explorador de archivos" aria-label="Explorador de archivos">${icons.folder(16)}</button>
        <button class="rc-tool" type="button" data-rc-action="activity" title="Abrir o cerrar Actividad" aria-label="Abrir o cerrar Actividad">${icons.brain(16)}</button>
        <button class="rc-tool" type="button" data-rc-action="menu" title="Menú de comandos (Ctrl+Shift+P)" aria-label="Menú de comandos">${icons.menu(16)}</button>
      </div>
      <div class="rc-cards">
        ${CARDS.map((card) => this.cardTemplate(card)).join('')}
      </div>
    `;
    this.paintEnvironment();
    this.paintContext();
    this.paintResults();
    this.paintChanges();
    this.paintTasks();
    this.paintSummaries();
  }

  private cardTemplate(card: RcCard): string {
    const collapsed = this.folded[card];
    const bodyId = `rc-${card}-body`;
    const chevron = collapsed ? icons.chevronRight(14) : icons.chevronDown(14);
    return `
      <section class="rc-card rc-card--${card}${collapsed ? ' is-folded' : ''}" data-rc-section="${card}">
        <button class="rc-card__head" type="button" data-rc-fold="${card}" aria-expanded="${collapsed ? 'false' : 'true'}" aria-controls="${bodyId}">
          <span class="rc-card__title">${esc(TITLES[card])}</span>
          <span class="rc-card__chevron" aria-hidden="true">${chevron}</span>
          <span class="rc-card__summary" data-rc-summary="${card}"></span>
        </button>
        <div class="rc-card__body" id="${bodyId}" ${collapsed ? 'hidden' : ''}></div>
      </section>`;
  }

  private body(card: RcCard): HTMLElement | null {
    return this.host.querySelector<HTMLElement>(`[data-rc-section="${card}"] .rc-card__body`);
  }

  /** Resumen de cada ventana, a la derecha de su cabecera cuando esta plegada. */
  private paintSummaries(): void {
    const set = (card: RcCard, html: string, title = ''): void => {
      const el = this.host.querySelector<HTMLElement>(`[data-rc-summary="${card}"]`);
      if (!el) return;
      el.innerHTML = html;
      if (title) el.title = title;
      else el.removeAttribute('title');
    };
    set('entorno', this.envLoaded && this.project ? `<span class="truncate">${esc(this.project)}</span>` : '', this.root);
    const pct = this.contextPercent();
    set(
      'contexto',
      pct === null
        ? ''
        : `<span class="rc-summary__num">${pct} %</span><span class="rc-mini" aria-hidden="true"><span class="rc-mini__fill" style="width:${pct}%"></span></span>`
    );
    set('resultados', `<span class="rc-summary__num">${this.conversationFiles().length}</span>`);
    set(
      'cambios',
      this.changesLoaded && !this.changesError && this.changes.length > 0
        ? `<span class="rc-changes__add">+${this.changesAdded}</span><span class="rc-changes__del">−${this.changesRemoved}</span>`
        : ''
    );
    const running = this.runningCount();
    set('tareas', running > 0 ? `<span class="rc-summary__num">${running} en curso</span>` : '');
  }

  /** Lo que se detendría al cerrar la ventana (aviso de cierre, QA 11-nov). */
  public backgroundSummary(): { terminal: boolean; orders: number; tasks: number } {
    return { terminal: this.terminalRunning, orders: this.runningOrders.size, tasks: this.runningTasks.size };
  }

  private runningCount(): number {
    return (this.terminalRunning ? 1 : 0) + this.runningOrders.size + this.runningTasks.size;
  }

  private paintEnvironment(): void {
    const body = this.body('entorno');
    if (!body) return;
    const project = this.envLoaded ? this.project || '—' : '…';
    const parent = this.parent
      ? `<span class="rc-env__parent rc-dim truncate" title="${escAttr(this.root)}">${esc(this.parent)}</span>`
      : '';
    const branchText = !this.isRepo ? 'sin git' : this.branch || (this.envLoaded ? '—' : '…');
    const sync =
      this.isRepo && (this.ahead > 0 || this.behind > 0)
        ? `<span class="rc-env__sync rc-dim" title="Commits por delante y por detrás del remoto">${this.ahead > 0 ? `↑${this.ahead}` : ''}${this.behind > 0 ? ` ↓${this.behind}` : ''}</span>`
        : '';
    body.innerHTML = `
      <div class="rc-env">
        <div class="rc-env__row" data-rc-env="computer">
          <span class="rc-env__icon" aria-hidden="true">${icons.monitor(16)}</span>
          <span class="rc-env__value truncate" title="Este equipo">Esta computadora</span>
        </div>
        <div class="rc-env__row" data-rc-env="project">
          <span class="rc-env__icon" aria-hidden="true">${icons.folder(16)}</span>
          <span class="rc-env__value rc-env__name truncate" title="${escAttr(this.root || project)}">${esc(project)}</span>
          ${parent}
        </div>
        <div class="rc-env__row" data-rc-env="branch">
          <span class="rc-env__icon" aria-hidden="true">${icons.fork(16)}</span>
          <span class="rc-env__value truncate" title="${escAttr(branchText)}">${esc(branchText)}</span>
          ${sync}
        </div>
        ${this.actions.changeWorkspace ? '<button type="button" class="btn btn--sm btn--ghost" data-rc-change-workspace>Cambiar la carpeta de trabajo</button>' : ''}
        <div class="rc-env__row rc-remote" data-rc-env="remote">
          <span class="rc-env__icon" aria-hidden="true">${icons.globe(16)}</span>
          <button type="button" class="btn btn--sm btn--ghost" data-rc-configure-remote>Configurar control remoto</button>
          <span class="rc-remote__state rc-dim" role="status">${this.remoteOn === null ? 'Desconocido' : this.remoteOn ? 'Activado' : 'Desactivado'}</span>
        </div>
      </div>`;
  }

  /** Porcentaje a mostrar: medido si hay ventana; si no, estimado; si no, null. */
  private contextPercent(): number | null {
    if (this.measured && this.measured.window > 0) {
      return Math.min(100, Math.round((this.measured.tokens / this.measured.window) * 100));
    }
    if (this.measured) return null;
    return this.contextPct;
  }

  private contextLevel(pct: number): string {
    if (pct >= 90) return 'danger';
    if (pct >= 70) return 'warn';
    return 'ok';
  }

  private paintContext(): void {
    const body = this.body('contexto');
    if (!body) return;
    const m = this.measured;
    let source = 'none';
    let pct: number | null = null;
    let main = '—';
    let label = 'Sin datos';
    let title = 'El uso aparecerá cuando el hilo tenga datos.';
    const rows: string[] = [];
    if (m) {
      source = 'measured';
      const where = [m.provider, m.model].filter(Boolean).join('/') || 'modelo desconocido';
      if (m.window > 0) {
        pct = Math.min(100, Math.round((m.tokens / m.window) * 100));
        main = `${pct} %`;
        label = `usado · ${formatTokens(m.tokens)} / ${formatTokens(m.window)}`;
        title = `Tokens de prompt de la última llamada (${where}) sobre la ventana de contexto del modelo.`;
        rows.push(this.ctxRow('Última llamada (prompt)', formatTokens(m.tokens)));
        if (this.contextTokens > 0) {
          rows.push(this.ctxRow('Historial de la conversación (estimado)', `~${formatTokens(this.contextTokens)}`));
        }
        rows.push(this.ctxRow('Libre', formatTokens(Math.max(0, m.window - m.tokens))));
      } else {
        main = formatTokens(m.tokens);
        label = 'tokens de prompt · ventana desconocida';
        title = `Última llamada (${where}). El catálogo no declara la ventana de contexto de este modelo, así que no se calcula un porcentaje.`;
        rows.push(this.ctxRow('Última llamada (prompt)', formatTokens(m.tokens)));
      }
    } else if (this.contextPct !== null) {
      source = 'estimated';
      pct = this.contextPct;
      main = `${pct} %`;
      label = 'Estimado';
      title = `El modelo no ha reportado uso: se estima por caracteres (${this.contextChars} caracteres ≈ ${this.contextTokens} tokens) sobre una ventana de ${formatTokens(ESTIMATE_WINDOW)}.`;
    }
    body.innerHTML = `
      <div class="rc-context" data-rc-context data-nivel="${pct === null ? '' : nivelContexto(pct)}" data-rc-context-source="${source}" data-pct="${pct === null ? '' : pct}">
        <div class="rc-context__head">
          <span class="rc-context__pct">${esc(main)}</span>
          <span class="rc-context__label rc-dim truncate" title="${escAttr(title)}">${esc(label)}</span>
        </div>
        <div class="rc-context__track" role="progressbar" aria-valuemin="0" aria-valuemax="100" ${pct === null ? '' : `aria-valuenow="${pct}"`}>
          <div class="rc-context__fill rc-context__fill--${pct === null ? 'none' : this.contextLevel(pct)}" style="width:${pct === null ? 0 : pct}%;${source === 'estimated' && pct !== null ? `background:${colorContexto(pct)}` : ''}"></div>
        </div>
        ${rows.length ? `<div class="rc-context__rows">${rows.join('')}</div>` : ''}
      </div>`;
  }

  private ctxRow(label: string, value: string): string {
    return `<div class="rc-ctxrow"><span class="rc-ctxrow__label truncate" title="${escAttr(label)}">${esc(label)}</span><span class="rc-ctxrow__value rc-dim">${esc(value)}</span></div>`;
  }

  private taskElapsed(startedAt: number, finishedAt = 0): string {
    const end = finishedAt > 0 ? finishedAt : Date.now();
    const total = Math.max(0, Math.floor((end - startedAt) / 1000));
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    const seconds = total % 60;
    const pad = (value: number): string => String(value).padStart(2, '0');
    return hours > 0 ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${pad(minutes)}:${pad(seconds)}`;
  }

  private taskStatusLabel(status: TaskStatus): string {
    switch (status) {
      case 'done':
        return 'Completada';
      case 'failed':
        return 'Fallida';
      case 'blocked':
        return 'Bloqueada';
      case 'cancelled':
        return 'Cancelada';
      default:
        return 'En curso';
    }
  }

  private taskRow(task: BackgroundTask): string {
    return `
      <div class="rc-task${task.orderId > 0 ? ' rc-task--order' : ''}" data-rc-task="${escAttr(task.id)}">
        <span class="rc-task__icon" aria-hidden="true">${icons.task(18)}</span>
        <span class="rc-task__name truncate" title="${escAttr(task.label)}">${esc(task.label)}</span>
        <span class="rc-task__time mono">${esc(this.taskElapsed(task.startedAt))}</span>
        <button class="rc-task__stop" type="button" data-rc-cancel-task="${escAttr(task.id)}" title="Cancelar esta tarea (pide confirmación)" aria-label="Cancelar ${escAttr(task.label)}">${icons.stop(16)}</button>
      </div>`;
  }

  private paintTasks(): void {
    const body = this.body('tareas');
    if (!body) return;
    let running = '';
    if (this.terminalRunning) {
      running += `
        <div class="rc-task rc-task--terminal" data-rc-terminal-row>
          <span class="rc-task__icon" aria-hidden="true">${icons.terminal(18)}</span>
          <span class="rc-task__name truncate" title="Terminal integrada">Terminal</span>
          <span class="rc-task__time mono">${esc(this.taskElapsed(this.terminalStartedAt || Date.now()))}</span>
          <button class="rc-task__stop" type="button" data-rc-kill-terminal title="Cerrar la terminal (pty.kill)" aria-label="Cerrar la terminal">${icons.stop(16)}</button>
        </div>`;
    }
    for (const task of this.runningOrders.values()) running += this.taskRow(task);
    for (const task of this.runningTasks.values()) running += this.taskRow(task);
    const finishedToggle = this.finishedTasks.length
      ? `<button class="rc-tasks__finished" type="button" data-rc-finished-toggle aria-expanded="${this.tasksShowFinished ? 'true' : 'false'}">
          <span>${this.finishedTasks.length} ${this.finishedTasks.length === 1 ? 'finalizado' : 'finalizados'}</span>
          <span class="rc-tasks__chevron" aria-hidden="true">${this.tasksShowFinished ? icons.chevronDown(14) : icons.chevronRight(14)}</span>
        </button>`
      : '';
    const finishedList =
      this.tasksShowFinished && this.finishedTasks.length
        ? `<div class="rc-tasks__done-list">${this.finishedTasks
            .map(
              (task) => `
            <div class="rc-task rc-task--done" data-rc-finished-task="${escAttr(task.id)}">
              <span class="rc-task__icon" aria-hidden="true">${icons.check(16)}</span>
              <span class="rc-task__name truncate" title="${escAttr(task.label)}">${esc(task.label)}</span>
              <span class="rc-task__status rc-dim">${esc(this.taskStatusLabel(task.status))}</span>
            </div>`
            )
            .join('')}</div>`
        : '';
    const empty =
      this.runningCount() === 0 && this.finishedTasks.length === 0
        ? '<div class="rc-empty">Sin tareas en segundo plano.</div>'
        : '';
    body.innerHTML = `${running}${empty}${finishedToggle}${finishedList}`;
    if (this.runningCount() > 0) this.startTasksTick();
    else this.stopTasksTick();
    this.paintSummaries();
  }

  private tickTasks(): void {
    if (this.destroyed) return;
    if (this.runningCount() === 0) {
      this.stopTasksTick();
      return;
    }
    const terminalTime = this.host.querySelector<HTMLElement>('[data-rc-terminal-row] .rc-task__time');
    if (terminalTime && this.terminalRunning) {
      terminalTime.textContent = this.taskElapsed(this.terminalStartedAt || Date.now());
    }
    for (const row of Array.from(this.host.querySelectorAll<HTMLElement>('[data-rc-task]'))) {
      const id = String(row.dataset.rcTask || '');
      const task =
        this.runningTasks.get(id) ||
        Array.from(this.runningOrders.values()).find((candidate) => candidate.id === id);
      const time = row.querySelector<HTMLElement>('.rc-task__time');
      if (task && time) time.textContent = this.taskElapsed(task.startedAt);
    }
    // Las ordenes de otras conversaciones solo se enteran por el motor.
    this.tickCount += 1;
    if (this.runningOrders.size > 0 && this.tickCount % ORDERS_POLL_EVERY_TICKS === 0 && this.isVisible()) {
      void this.refreshOrders();
    }
  }

  private startTasksTick(): void {
    if (this.tasksTick !== null || this.destroyed) return;
    this.tasksTick = window.setInterval(() => this.tickTasks(), 1000) as unknown as number;
  }

  private stopTasksTick(): void {
    if (this.tasksTick === null) return;
    window.clearInterval(this.tasksTick);
    this.tasksTick = null;
  }

  /**
 * (tanda 1): la fila dice DÓNDE está el archivo, como en Codex o
   * Claude Code. Con solo el nombre, `docs/uno.txt` y `uno.txt` se veían
   * iguales. La carpeta va atenuada delante del nombre, relativa a la raíz.
   */
  private pathLabel(path: string): string {
    const root = this.root.replace(/[\\/]+$/, '');
    let rel = path;
    if (root && path.length > root.length && path.toLowerCase().startsWith(root.toLowerCase()) &&
        (path[root.length] === '\\' || path[root.length] === '/')) {
      rel = path.slice(root.length + 1);
    }
    const cut = Math.max(rel.lastIndexOf('/'), rel.lastIndexOf('\\'));
    const name = rel.slice(cut + 1) || rel;
    const dir = cut > 0 ? rel.slice(0, cut + 1) : '';
    return `${dir ? `<span class="subtle">${esc(dir)}</span>` : ''}${esc(name)}`;
  }

  private fileRow(path: string): string {
    const name = path.split(/[\\/]/).pop() || path;
    const icon = fileIcon(name, 16);
    return `
      <button class="rc-file" type="button" data-rc-file="${escAttr(path)}" title="${escAttr(path)}">
        <span class="rc-file__icon" style="color:${icon.color}" aria-hidden="true">${icon.svg}</span>
        <span class="rc-file__name truncate">${this.pathLabel(path)}</span>
      </button>`;
  }

  private paintResults(): void {
    const body = this.body('resultados');
    if (!body) return;
    const files = this.conversationFiles();
    const total = files.length;
    this.paintSummaries();
    if (total === 0) {
      body.innerHTML =
        '<div class="rc-empty">Aún no hay archivos. Lo que escriba el agente en esta conversación aparecerá aquí.</div>';
      return;
    }
    const limit = this.showAllFiles ? total : Math.min(total, VISIBLE_FILES);
    let rows = '';
    for (let i = 0; i < limit; i++) rows += this.fileRow(files[i]);
    const more =
      !this.showAllFiles && total > VISIBLE_FILES
        ? `<button class="rc-more" type="button" data-rc-more>Mostrar más (${total - VISIBLE_FILES})<span aria-hidden="true">${icons.arrowRight(14)}</span></button>`
        : '';
    body.innerHTML = `<div class="rc-files">${rows}</div>${more}`;
  }

  /**
   * Fila de un archivo cambiado. El nombre se escapa SIEMPRE (un archivo se
   * llama como quiere el usuario). Un archivo sin seguimiento no tiene diff
   * todavia y se rotula «nuevo» en vez de inventar ceros.
   */
  private changeRow(file: RightCardsGitFile): string {
    const name = file.path.split(/[\\/]/).pop() || file.path;
    const icon = fileIcon(name, 16);
    const counts = file.untracked
      ? '<span class="rc-change__new">nuevo</span>'
      : `<span class="rc-change__add">+${file.added}</span><span class="rc-change__del">−${file.removed}</span>`;
    return `
      <button class="rc-change" type="button" data-rc-change="${escAttr(file.path)}" title="${escAttr(file.path)}">
        <span class="rc-change__icon" style="color:${icon.color}" aria-hidden="true">${icon.svg}</span>
        <span class="rc-change__name truncate">${this.pathLabel(file.path)}</span>
        <span class="rc-change__counts">${counts}</span>
      </button>`;
  }

  /** Ruta relativa de git -> absoluta dentro de la raiz autorizada. */
  private absoluteChangePath(rel: string): string {
    if (!rel) return '';
    if (/^[a-zA-Z]:[\\/]/.test(rel) || rel.startsWith('\\\\') || rel.startsWith('/')) return rel;
    const root = this.root.replace(/[\\/]+$/, '');
    if (!root) return rel;
    const separator = root.includes('\\') ? '\\' : '/';
    return root + separator + rel.replace(/[\\/]+/g, separator);
  }

  private canConfirm(): boolean {
    return (
      this.changesLoaded &&
      !this.changesError &&
      this.changesRepo &&
      this.changes.length > 0 &&
      !this.confirmBusy
    );
  }

  /** Por que esta desactivado el boton (o que hace al pulsarlo). */
  private confirmReason(): string {
    if (!this.changesLoaded) return 'Leyendo el estado de git';
    if (this.changesError) return 'No se pudo leer el estado de git';
    if (!this.changesRepo) return 'La carpeta no es un repositorio git';
    if (this.changes.length === 0) return 'No hay cambios que confirmar';
    if (this.confirmBusy) return 'Confirmando…';
    return 'Revisa los archivos y el mensaje antes de crear el commit local';
  }

  private paintChanges(): void {
    const body = this.body('cambios');
    if (!body) return;
    const counts = `<span class="rc-changes__counts" aria-label="${escAttr(
      `Añadidas ${this.changesAdded}, quitadas ${this.changesRemoved}`
    )}"><span class="rc-changes__add">+${this.changesAdded}</span><span class="rc-changes__del">−${this.changesRemoved}</span></span>`;
    const refresh = `<button class="rc-iconbtn" type="button" data-rc-refresh title="Refrescar cambios" aria-label="Refrescar cambios">${icons.refresh(16)}</button>`;
    // «Confirmar cambios» va en la cabecera de la ventana, junto a «+A −R».
    const confirm = `<button class="rc-confirm" type="button" data-rc-confirm ${this.canConfirm() ? '' : 'disabled'} title="${escAttr(
      this.confirmReason()
    )}">${icons.check(14)}<span>Confirmar</span></button>`;
    let content = '';
    if (!this.changesLoaded) {
      content = '<div class="rc-empty">Leyendo el estado de git…</div>';
    } else if (this.changesError) {
      content = `<div class="rc-changes__error">${esc(this.changesError)}</div>`;
    } else if (!this.changesRepo) {
      content = '<div class="rc-empty">Esta carpeta no es un repositorio git.</div>';
    } else if (this.changes.length === 0) {
      content = '<div class="rc-empty">Sin cambios pendientes: el árbol de trabajo está limpio.</div>';
    } else {
      const total = this.changes.length;
      const limit = this.changesShowAll ? total : Math.min(total, VISIBLE_FILES);
      let rows = '';
      for (let i = 0; i < limit; i++) rows += this.changeRow(this.changes[i]);
      const more =
        !this.changesShowAll && total > VISIBLE_FILES
          ? `<button class="rc-changes__more" type="button" data-rc-changes-more>Mostrar más (${total - VISIBLE_FILES})<span aria-hidden="true">${icons.arrowRight(14)}</span></button>`
          : '';
      const truncated = this.changesTruncated
        ? '<div class="rc-dim">La lista se cortó en el host.</div>'
        : '';
      content = `<div class="rc-changes__files">${rows}</div>${more}${truncated}`;
    }
    body.innerHTML = `
      <div class="rc-changes__head">${counts}<span class="rc-changes__actions">${refresh}${confirm}</span></div>
      ${content}`;
  }

  /** Modal: lista completa + mensaje editable. Solo «Confirmar» llama a
   *  core.git.commit; cancelar o Escape no ejecutan git. */
  private openCommitModal(): void {
    if (!this.canConfirm()) return;
    this.host.querySelector('[data-rc-modal]')?.remove();
    const dialog = document.createElement('dialog');
    dialog.className = 'rc-modal';
    dialog.setAttribute('data-rc-modal', '');
    const fileRows = this.changes
      .map((file) => `<div class="rc-modal__file" title="${escAttr(file.path)}">${esc(file.path)}</div>`)
      .join('');
    dialog.innerHTML = `
      <div class="rc-modal__title">Confirmar cambios</div>
      <div class="rc-modal__subtitle">Crea un commit local en la rama actual. No hace push.</div>
      <div class="rc-modal__files">${fileRows}</div>
      <label class="rc-modal__label" for="rc-commit-message">Mensaje del commit</label>
      <textarea class="rc-modal__message" id="rc-commit-message" rows="4" placeholder="Describe el cambio" aria-label="Mensaje del commit"></textarea>
      <div class="rc-modal__error" hidden></div>
      <div class="rc-modal__actions">
        <button class="rc-modal__btn" type="button" data-rc-cancel>Cancelar</button>
        <button class="rc-modal__btn rc-modal__btn--primary" type="button" data-rc-modal-confirm>Confirmar</button>
      </div>`;
    this.host.appendChild(dialog);
    dialog.showModal();
    dialog.querySelector<HTMLTextAreaElement>('.rc-modal__message')?.focus();
  }

  private async confirmCommit(): Promise<void> {
    const dialog = this.host.querySelector<HTMLDialogElement>('[data-rc-modal]');
    if (!dialog || this.confirmBusy) return;
    const textarea = dialog.querySelector<HTMLTextAreaElement>('.rc-modal__message');
    const errorBox = dialog.querySelector<HTMLElement>('.rc-modal__error');
    const message = String(textarea?.value || '').trim();
    if (!message) {
      if (errorBox) {
        errorBox.hidden = false;
        errorBox.textContent = 'Escribe el mensaje del commit.';
      }
      textarea?.focus();
      return;
    }
    this.confirmBusy = true;
    const buttons = dialog.querySelectorAll<HTMLButtonElement>('button');
    for (const button of buttons) button.disabled = true;
    try {
      const result = await this.core.gitCommit({
        root: this.root,
        message,
        files: this.changes.map((file) => file.path),
      });
      const hash = String(result?.hash || '');
      this.confirmBusy = false;
      dialog.close();
      dialog.remove();
      notice(hash ? `Commit creado: ${hash.slice(0, 10)}` : 'Commit creado', 'ok');
      await this.refreshChanges();
    } catch (error) {
      this.confirmBusy = false;
      for (const button of buttons) button.disabled = false;
      const detail = String((error as { message?: string })?.message || error);
      if (errorBox) {
        errorBox.hidden = false;
        errorBox.textContent = 'git no pudo completar el commit: ' + detail;
      }
      notice('No se pudo confirmar el commit: ' + detail, 'error');
    }
  }

  private findRunning(taskId: string): BackgroundTask | undefined {
    return (
      this.runningTasks.get(taskId) ||
      Array.from(this.runningOrders.values()).find((task) => task.id === taskId)
    );
  }

  private openCancelModal(taskId: string): void {
    const task = this.findRunning(taskId);
    if (!task) return;
    this.host.querySelector('[data-rc-task-modal]')?.remove();
    const orderId = task.orderId > 0 ? task.orderId : Number(this.actions.activeOrderId()) || 0;
    const dialog = document.createElement('dialog');
    dialog.className = 'rc-modal';
    dialog.setAttribute('data-rc-task-modal', '');
    dialog.dataset.rcTaskOrder = String(orderId > 0 ? orderId : 0);
    dialog.dataset.rcTaskId = taskId;
    dialog.innerHTML = `
      <div class="rc-modal__title">Cancelar tarea</div>
      <div class="rc-modal__subtitle">La tarea «${esc(task.label)}» se cancelará junto con la orden #${orderId > 0 ? orderId : '—'}.</div>
      <div class="rc-modal__error" hidden></div>
      <div class="rc-modal__actions">
        <button class="rc-modal__btn" type="button" data-rc-task-abort>Volver</button>
        <button class="rc-modal__btn rc-modal__btn--primary" type="button" data-rc-task-confirm>Cancelar tarea</button>
      </div>`;
    this.host.appendChild(dialog);
    dialog.showModal();
  }

  private async confirmCancelTask(): Promise<void> {
    const dialog = this.host.querySelector<HTMLDialogElement>('[data-rc-task-modal]');
    if (!dialog || this.cancelBusy) return;
    const errorBox = dialog.querySelector<HTMLElement>('.rc-modal__error');
    const orderId = Number(dialog.dataset.rcTaskOrder) || 0;
    const taskId = String(dialog.dataset.rcTaskId || '');
    if (!(orderId > 0)) {
      if (errorBox) {
        errorBox.hidden = false;
        errorBox.textContent = 'No hay una orden activa que cancelar.';
      }
      return;
    }
    this.cancelBusy = true;
    const buttons = dialog.querySelectorAll<HTMLButtonElement>('button');
    for (const button of buttons) button.disabled = true;
    try {
      const result = await this.core.cancelOrder(orderId);
      if (result?.cancelled === false) throw new Error('el motor no confirmó la cancelación');
      const ts = Date.now();
      const order = Array.from(this.runningOrders.values()).find((task) => task.orderId === orderId);
      if (order) {
        this.runningOrders.delete(orderId);
        if (!this.finishedIds.has(order.id)) {
          this.finishedIds.add(order.id);
          this.finishedTasks.unshift({ ...order, status: 'cancelled', finishedAt: ts });
        }
      }
      if (!taskId.startsWith('order-') || orderId === (Number(this.actions.activeOrderId()) || 0)) {
        for (const id of Array.from(this.runningTasks.keys())) this.finishTask(id, 'cancelled', ts);
      }
      this.cancelBusy = false;
      dialog.close();
      dialog.remove();
      this.paintTasks();
      notice(`Cancelación solicitada para la orden #${orderId}`, 'ok');
    } catch (error) {
      this.cancelBusy = false;
      for (const button of buttons) button.disabled = false;
      const detail = String((error as { message?: string })?.message || error);
      if (errorBox) {
        errorBox.hidden = false;
        errorBox.textContent = 'No se pudo cancelar: ' + detail;
      }
      notice('No se pudo cancelar la tarea: ' + detail, 'error');
    }
  }

  private handleClick(e: MouseEvent): void {
    const target = e.target as HTMLElement | null;
    if (!target || typeof target.closest !== 'function') return;
    const action = target.closest<HTMLElement>('[data-rc-action]');
    if (action) {
      this.runAction(String(action.dataset.rcAction || ''));
      return;
    }
    if (target.closest('[data-rc-configure-remote]')) {
      document.dispatchEvent(new CustomEvent('devagents:settings-section', { detail: 'remote' }));
      return;
    }
    if (target.closest('[data-rc-change-workspace]')) {
      this.actions.changeWorkspace?.();
      return;
    }
    const file = target.closest<HTMLElement>('[data-rc-file]');
    if (file) {
      const path = String(file.dataset.rcFile || '');
      if (path) document.dispatchEvent(new CustomEvent('devagents:open-file', { detail: path }));
      return;
    }
    if (target.closest('[data-rc-more]')) {
      this.showAllFiles = true;
      this.paintResults();
      return;
    }
    if (target.closest('[data-rc-changes-more]')) {
      this.changesShowAll = true;
      this.paintChanges();
      return;
    }
    if (target.closest('[data-rc-refresh]')) {
      void this.refreshChanges();
      return;
    }
    if (target.closest('[data-rc-kill-terminal]')) {
      this.terminalRunning = false;
      this.terminalId = 0;
      this.terminalStartedAt = 0;
      document.dispatchEvent(new CustomEvent('devagents:terminal-stop'));
      this.paintTasks();
      return;
    }
    const cancelTask = target.closest<HTMLElement>('[data-rc-cancel-task]');
    if (cancelTask) {
      this.openCancelModal(String(cancelTask.dataset.rcCancelTask || ''));
      return;
    }
    if (target.closest('[data-rc-task-abort]')) {
      this.host.querySelector('[data-rc-task-modal]')?.remove();
      return;
    }
    if (target.closest('[data-rc-task-confirm]')) {
      void this.confirmCancelTask();
      return;
    }
    if (target.closest('[data-rc-finished-toggle]')) {
      this.tasksShowFinished = !this.tasksShowFinished;
      this.paintTasks();
      return;
    }
    const change = target.closest<HTMLElement>('[data-rc-change]');
    if (change) {
      const path = this.absoluteChangePath(String(change.dataset.rcChange || ''));
      if (path) document.dispatchEvent(new CustomEvent('devagents:open-file', { detail: path }));
      return;
    }
    if (target.closest('[data-rc-confirm]')) {
      this.openCommitModal();
      return;
    }
    if (target.closest('[data-rc-cancel]')) {
      this.host.querySelector('[data-rc-modal]')?.remove();
      return;
    }
    if (target.closest('[data-rc-modal-confirm]')) {
      void this.confirmCommit();
      return;
    }
    const fold = target.closest<HTMLElement>('[data-rc-fold]');
    if (fold) {
      const value = String(fold.dataset.rcFold || '') as RcCard;
      this.toggleFold(CARDS.includes(value) ? value : 'entorno');
    }
  }

  private toggleFold(card: RcCard): void {
    this.folded[card] = !this.folded[card];
    this.writeFold();
    const collapsed = this.folded[card];
    const section = this.host.querySelector<HTMLElement>(`[data-rc-section="${card}"]`);
    const head = section?.querySelector<HTMLElement>('[data-rc-fold]');
    const body = section?.querySelector<HTMLElement>('.rc-card__body');
    const chevron = section?.querySelector<HTMLElement>('.rc-card__chevron');
    section?.classList.toggle('is-folded', collapsed);
    if (head) head.setAttribute('aria-expanded', String(!collapsed));
    if (body) body.hidden = collapsed;
    if (chevron) chevron.innerHTML = collapsed ? icons.chevronRight(14) : icons.chevronDown(14);
  }

  private runAction(action: string): void {
    switch (action) {
      case 'panel':
        this.actions.togglePanel();
        break;
      case 'activity':
        this.actions.toggleActivity?.();
        break;
      case 'terminal':
        this.actions.toggleTerminal();
        break;
      case 'browser':
        this.actions.toggleBrowser();
        break;
      case 'explorer':
        this.actions.showExplorer();
        break;
      case 'menu':
        this.actions.showMenu();
        break;
    }
  }
}
