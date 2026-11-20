import { escapeText as esc, escapeAttribute, html as safeHtml, joinHtml, raw, setHtml, asSafeHtml, SafeHtml } from '../design/html';
import { CoreApi, FsEntry, SessionInfo, OrderEvent, eventPayload } from '../bridge/core_api';
import { icons } from '../design/icons';
import { ViewId, formatEngineVersion } from '../layout/layout';
import { XtermTerminal } from '../terminal/xterm_terminal';
import { SpacesPanel } from '../panes/SpacesPanel';
import { fileIcon, folderIcon } from '../design/file_icons';
import { notice } from '../design/notice';
import { promptModal, confirmModal } from '../design/modal';
import { estadoDeSesion, delegacionIncompleta } from '../design/status_labels';
// S8: agrupado y busqueda de sesiones, aparte para poder probarlos sin DOM.
import { grupoPorFecha, coincideBusqueda, agruparPorConversacion, planPendienteVigente, ordenarPorReciente, visibleEnBarra, esArchivable } from '../session_groups';
// P3 (corrección auditoría): coalescing del refresco de la lista de sesiones,
// aparte para poder probarlo sin DOM.
import { RefreshCoalescer } from './refresh_coalescer';
import { SETTINGS_SECTIONS } from '../panes/settings_memory';
import { previewHtml } from '../editor/diff_viewer';
import { pareceBinario } from '../editor/binario';

/**
 * E2.11 — categorías persistentes por sesión. Viven en localStorage porque
 * son un criterio del USUARIO sobre SU vista (como el filtro o el tema), no
 * un dato del motor: la orden no sabe si su trabajo es «Trabajo» o «Personal».
 * El mapa es orderId → etiqueta; la clave '' quita la categoría.
 */
const SESSION_CATS_KEY = 'devagents.session-cats';
export const SESSION_CATEGORIES = ['Trabajo', 'Personal', 'Experimento', 'Investigación'];

function sessionCats(): Record<string, string> {
  try {
    const m = JSON.parse(window.localStorage.getItem(SESSION_CATS_KEY) || '{}');
    return m && typeof m === 'object' ? m as Record<string, string> : {};
  } catch {
    return {};
  }
}

function setSessionCat(orderId: number, cat: string): void {
  try {
    const m = sessionCats();
    if (cat) m[String(orderId)] = cat;
    else delete m[String(orderId)];
    window.localStorage.setItem(SESSION_CATS_KEY, JSON.stringify(m));
  } catch {
    // Sin almacenamiento la categoría no persiste; la sesión sigue funcionando.
  }
}

/**
 * Firma de la lista de sesiones para decidir si una revalidación trajo algo
 * nuevo. Cubre lo que la fila muestra (título, estado, hilo) — si la firma
 * coincide, la repinta sería idéntica y se omite.
 */
function sesionesSignature(sessions: SessionInfo[]): string {
  return sessions
    .map((s) =>
      [
        s.order_id ?? s.id ?? 0,
        s.title ?? '',
        s.status_text ?? s.status ?? '',
        s.conversation_id ?? '',
        // archivar/restaurar no cambia título ni estado; sin este
        // campo la firma coincidiría y la fila archivada seguiría en pantalla.
        s.archived_at ?? 0,
      ].join(':')
    )
    .join('|');
}

interface PaneRefs {
  mission: HTMLElement | null;
  editor: HTMLElement | null;
  verification: HTMLElement | null;
  catalog: HTMLElement | null;
  settings: HTMLElement | null;
  mcp: HTMLElement | null;
  issues: HTMLElement | null;
  monitor: HTMLElement | null;
  diff: HTMLElement | null;
}

export interface ViewRouterHooks {
  hasUnsavedChanges?: (path: string) => boolean;
  onFilesReplaced?: (paths: string[]) => Promise<void>;
  onOpenFile?: (path: string, name: string) => void;
  onOpenSession?: (orderId: number, conversationId?: string | null) => void;
  /** Abre una URL en el navegador del sistema (resultados de búsqueda web). */
  onOpenExternal?: (url: string) => void;
  /** Rompe el hilo actual y empieza una conversación nueva con el agente. */
  onNewConversation?: () => void;
}

/**
 * Enrutador de vistas de la cabina.
 *
 * En la maqueta la barra de actividad era decorativa: solo un icono tenia
 * listener y no cambiaba nada. Aqui cada icono selecciona una vista, decide
 * que panel central se muestra y que se pinta en la barra lateral, con datos
 * reales pedidos al motor.
 */
const SESS_GROUPS_KEY = 'devagents.sessgroups.v1';
/** Grupos de sesiones plegados por el usuario: título → true si plegado. */
function sessGroupState(): Record<string, boolean> {
  try {
    const raw = window.localStorage.getItem(SESS_GROUPS_KEY);
    const v = raw ? JSON.parse(raw) : {};
    return v && typeof v === 'object' ? v : {};
  } catch {
    return {};
  }
}
function saveSessGroupState(v: Record<string, boolean>): void {
  try {
    window.localStorage.setItem(SESS_GROUPS_KEY, JSON.stringify(v));
  } catch {
    // Recordar el plegado es una comodidad.
  }
}
/** Color del punto de una sesión (maqueta: ok, bad, run, warn o neutro). */
function sessDotClass(estado: string, porAprobar: boolean): string {
  if (porAprobar) return 'warn';
  const e = estado.toLowerCase();
  if (/fail|error|abort|cancel/.test(e)) return 'bad';
  if (/running|executing|planning|in_progress|progress|working|verifying|auditing/.test(e)) return 'run';
  if (/done|complet|success|ok|hecha/.test(e)) return 'ok';
  if (/planned|pending|await|wait/.test(e)) return 'warn';
  return 'idle';
}

export class ViewRouter {
  private current: ViewId = 'agent';
  private panes: PaneRefs;
  private expandedDirs = new Set<string>();
  private treeRoot = '';
  private terminal: XtermTerminal | null = null;
  private terminalReady: Promise<void> | null = null;
  private terminalContainer: HTMLElement | null = null;
  private spacesPanel: SpacesPanel | null = null;

  constructor(
    private core: CoreApi,
    private hooks: ViewRouterHooks = {}
  ) {
    this.panes = {
      mission: document.getElementById('pane-mission-container'),
      editor: document.getElementById('monaco-editor-container'),
      verification: document.getElementById('pane-verification-container'),
      catalog: document.getElementById('pane-catalog-container'),
      settings: document.getElementById('pane-settings-container'),
      mcp: document.getElementById('pane-mcp-container'),
      issues: document.getElementById('pane-issues-container'),
      monitor: document.getElementById('pane-monitor-container'),
      diff: document.getElementById('pane-diff-container'),
    };
    this.bindActivityBar();
    this.bindBottomPanel();
    this.listenEngineOutput();
    this.sessionsRefresher = new RefreshCoalescer(() => this.revalidateSessions());
    // (c): en B las secciones abiertas se pintan ya al arrancar, y
    // Sesiones necesita el refresco de la lista: va después de crearlo.
    this.bindLayout();
  }

  public getCurrent(): ViewId {
    return this.current;
  }

  private bindActivityBar(): void {
    document.querySelectorAll<HTMLElement>('.activity-bar__item').forEach((el) => {
      el.addEventListener('click', () => {
        const view = el.dataset.view as ViewId | undefined;
        if (!view) return;
        // pulsar un icono con la barra lateral plegada es pedir ver
        // ESE panel, así que la barra se despliega. Antes el clic cambiaba la
        // vista pero la barra seguía en su franja de 38 px: parecía que no
        // pasaba nada. Se reutiliza el botón de plegar (misma clave de
        // localStorage, mismo icono y título) para no duplicar su estado.
        const sidebar = document.getElementById('sidebar-primary');
        if (sidebar?.dataset.collapsed === 'true') {
          document.getElementById('btn-sidebar-collapse')?.click();
        }
        this.show(view);
        // (c): en B la franja solo existe con el panel plegado;
        // pulsar un icono despliega el panel con ESA sección abierta.
        if (this.isUnified() && !this.openSet().has(view)) this.openSection(view, true);
      });
    });
  }

  // --- (c): disposición B · Unificada ---------------------------
  //
  // Maqueta v2, página 1 (uniSide/navSec): cada vista es una sección
  // plegable del mismo panel, con su propio contenido y sus botones en la
  // cabecera, siempre visibles. 9-nov (prueba del propietario): con varias abiertas
  // el panel se llenaba y confundía, así que Sesiones va aparte y de las de
  // abajo solo hay UNA abierta: abrir otra cierra la anterior. Spaces ya no es
  // sección: cada orden crea el suyo sola; se gestiona en la vista central
  // «Spaces y sesiones». Abrir una sección no cambia el panel central: lo
  // cambian sus enlaces «Abrir …» y la navegación de siempre (show). En A nada
  // de esto existe y la barra lateral sigue siendo #sidebar-body por vista.

  /** Orden, nombres e iconos de la maqueta (pág. 1, SECS). */
  private static readonly SECTIONS: Array<{ view: ViewId; label: string; icon: (s?: number) => string; open?: string }> = [
    { view: 'agent', label: 'Sesiones', icon: icons.sessions },
    { view: 'explorer', label: 'Archivos', icon: icons.files },
    { view: 'search', label: 'Búsqueda', icon: icons.search },
    { view: 'mcp', label: 'Conectores MCP', icon: icons.plug, open: 'Abrir Conectores MCP' },
    { view: 'issues', label: 'Incidencias', icon: icons.issues, open: 'Abrir Incidencias' },
    { view: 'monitor', label: 'Monitor', icon: icons.monitor, open: 'Abrir el Monitor' },
  ];
  private static readonly OPEN_KEY = 'devagents.sections.v1';
  /** Secciones abiertas (se guardan); por defecto solo Sesiones, como la maqueta. */
  private openSecs: Set<ViewId> | null = null;
  /** Firma de lo pintado en #sidebar-sections ('A' o 'B'). */
  private sectionsSig = '';

  private isUnified(): boolean {
    // Igual que el CSS: B solo con data-layout="B" (lo pone initLayout). Sin
    // atributo se comporta como A.
    return document.documentElement.dataset.layout === 'B';
  }

  private openSet(): Set<ViewId> {
    if (this.openSecs) return this.openSecs;
    let list: ViewId[] = ['agent'];
    try {
      const raw = localStorage.getItem(ViewRouter.OPEN_KEY);
      const parsed = raw ? JSON.parse(raw) : null;
      if (Array.isArray(parsed)) list = parsed.filter((v) => ViewRouter.SECTIONS.some((s) => s.view === v));
    } catch {
      // Sin localStorage: solo Sesiones abierta.
    }
    // Lo guardado antes del 9-nov podía traer varias de abajo abiertas: se
    // conserva Sesiones y la última de las demás.
    const others = list.filter((v) => v !== 'agent');
    list = [...(list.includes('agent') ? (['agent'] as ViewId[]) : []), ...others.slice(-1)];
    this.openSecs = new Set(list);
    return this.openSecs;
  }

  private saveOpen(): void {
    try {
      localStorage.setItem(ViewRouter.OPEN_KEY, JSON.stringify([...this.openSet()]));
    } catch {
      // Recordar las secciones es una comodidad; sin almacenamiento no se pierde nada.
    }
  }

  /** ¿Se ve ahora el contenido lateral de esta vista? (B: sección abierta; A: vista activa). */
  private isShown(view: ViewId): boolean {
    if (this.isUnified()) {
      const wrap = document.getElementById('sb-body-' + view);
      return !!wrap && wrap.isConnected && !wrap.hidden;
    }
    return this.current === view;
  }

  /** Dónde pintar el contenido lateral de una vista, o null si no se ve. */
  private hostFor(view: ViewId): { body: HTMLElement; actions: HTMLElement | null } | null {
    if (!this.isShown(view)) return null;
    if (this.isUnified()) {
      const body = document.querySelector<HTMLElement>(`#sb-body-${view} > .sb-sec__content`);
      return body ? { body, actions: null } : null;
    }
    const body = document.getElementById('sidebar-body');
    return body ? { body, actions: document.getElementById('sidebar-actions') } : null;
  }

  private bindLayout(): void {
    // Pie del panel (B): «Configuración» es navegación, como su icono de la franja.
    document.getElementById('sb-foot-settings')?.addEventListener('click', () => this.show('settings'));
    const host = document.getElementById('sidebar-sections');
    host?.addEventListener('click', (ev) => {
      const t = ev.target as HTMLElement;
      const toggle = t.closest<HTMLElement>('.sb-sec__toggle');
      if (toggle) {
        const view = toggle.closest<HTMLElement>('.sb-sec')?.dataset.view as ViewId | undefined;
        if (view) this.toggleSection(view);
        return;
      }
      const link = t.closest<HTMLElement>('[data-sec-open]');
      if (link) {
        ev.preventDefault();
        this.show(link.dataset.secOpen as ViewId);
      }
    });
    document.addEventListener('devagents:layout-changed', () => {
      if (this.isUnified()) {
        // Lo que A pintó en su barra lateral no se ve en B y duplicaría ids
        // (#sb-sess-filter, #search-input, #space-new…): se retira.
        this.spacesPanel?.detach();
        const oldBody = document.getElementById('sidebar-body');
        const oldActions = document.getElementById('sidebar-actions');
        if (oldBody) oldBody.innerHTML = '';
        if (oldActions) oldActions.innerHTML = '';
        this.renderSections(true);
        return;
      }
      // A: se retiran las secciones y la barra lateral de la vista activa se
      // pinta ya (si no, el panel quedaba vacío hasta pulsar un icono).
      this.renderSections(true);
      this.show(this.current);
    });
    this.renderSections(true);
  }

  /** Pinta las secciones (B) o las retira (A). Solo repinta si cambia la disposición. */
  private renderSections(force = false): void {
    const host = document.getElementById('sidebar-sections');
    if (!host) return;
    const want = this.isUnified() ? 'B' : 'A';
    if (!force && want === this.sectionsSig && (want === 'A' || host.childElementCount > 0)) return;
    this.sectionsSig = want;
    const collapse = document.getElementById('btn-sidebar-collapse');
    const headerTools = document.getElementById('sidebar-header-tools');
    if (want === 'A') {
      // El botón de plegar vuelve a la cabecera de A y las secciones se vacían.
      if (collapse && headerTools && !headerTools.contains(collapse)) headerTools.appendChild(collapse);
      host.innerHTML = '';
      return;
    }
    const open = this.openSet();
    host.innerHTML = ViewRouter.SECTIONS.map((s) => {
      const isOpen = open.has(s.view);
      const v = escapeAttribute(s.view);
      return `<div class="sb-sec${isOpen ? ' is-open' : ''}" data-view="${v}">
          <div class="sb-sec__head">
            <button class="sb-sec__toggle" id="sb-sec-${v}" aria-expanded="${isOpen}" aria-controls="sb-body-${v}"><span class="sb-sec__ico">${s.icon(14)}</span><span class="sb-sec__label">${esc(s.label)}</span></button>
            <span class="sb-sec__tools" id="sb-tools-${v}"></span>
          </div>
          <div class="sb-sec__body" id="sb-body-${v}" role="region" aria-labelledby="sb-sec-${v}"${isOpen ? '' : ' hidden'}>
            <div class="sb-sec__content"></div>${s.open ? `<a href="#" class="sb-sec__link" data-sec-open="${v}">${esc(s.open)}</a>` : ''}
          </div>
        </div>`;
    }).join('');
    this.renderSectionTools();
    // (e): un solo control de la barra lateral, arriba a la izquierda.
    if (collapse) document.getElementById('titlebar-sidebar-slot')?.appendChild(collapse);
    for (const s of ViewRouter.SECTIONS) if (open.has(s.view)) this.renderSection(s.view);
  }

  /** Botones de la cabecera de cada sección (maqueta: navSec, archMenu). */
  private renderSectionTools(): void {
    const tool = (id: string, title: string, icon: string): string =>
      `<button class="icon-btn" id="${id}" title="${escapeAttribute(title)}" aria-label="${escapeAttribute(title)}">${icon}</button>`;
    const agent = document.getElementById('sb-tools-agent');
    if (agent) {
      agent.innerHTML = '<span class="row" id="sb-agent-actions" style="gap:2px"></span>';
      const a = agent.querySelector<HTMLElement>('#sb-agent-actions');
      if (a) this.renderSessionActions(a);
    }
    const files = document.getElementById('sb-tools-explorer');
    if (files) {
      files.innerHTML = tool('sb-tree-refresh', 'Actualizar árbol', icons.refresh(13));
      files.querySelector('#sb-tree-refresh')?.addEventListener('click', () => {
        this.expandedDirs.clear();
        this.openSection('explorer');
      });
    }
    const mcp = document.getElementById('sb-tools-mcp');
    if (mcp) {
      mcp.innerHTML = '<span class="sb-sec__dot" id="sb-mcp-dot" title="Consultando el servidor MCP…"></span>';
      void this.core
        .mcpStatus()
        .then((st) => {
          const dot = document.getElementById('sb-mcp-dot');
          if (!dot) return;
          dot.classList.toggle('is-ok', !!st.connected);
          dot.title = st.connected ? 'Servidor MCP conectado' : 'Sin servidor MCP';
        })
        .catch(() => {
          const dot = document.getElementById('sb-mcp-dot');
          if (dot) dot.title = 'No se pudo consultar el servidor MCP';
        });
    }
    const monitor = document.getElementById('sb-tools-monitor');
    if (monitor) {
      monitor.innerHTML = tool('sb-monitor-refresh', 'Actualizar', icons.refresh(13));
      monitor.querySelector('#sb-monitor-refresh')?.addEventListener('click', () => this.openSection('monitor'));
    }
  }

  private toggleSection(view: ViewId): void {
    const open = this.openSet();
    if (open.has(view)) {
      open.delete(view);
      this.saveOpen();
      this.setSectionOpen(view, false);
      return;
    }
    this.openSection(view);
  }

  /** Abre una sección (si hace falta) y pinta su contenido. */
  private openSection(view: ViewId, focusScroll = false): void {
    if (!ViewRouter.SECTIONS.some((s) => s.view === view)) return;
    const open = this.openSet();
    if (!open.has(view)) {
      // Una sola de las de abajo a la vez (Sesiones va aparte).
      if (view !== 'agent') {
        for (const other of [...open]) {
          if (other === 'agent') continue;
          open.delete(other);
          this.setSectionOpen(other, false);
        }
      }
      open.add(view);
      this.saveOpen();
    }
    this.setSectionOpen(view, true);
    this.renderSection(view);
    if (focusScroll) document.getElementById('sb-sec-' + view)?.scrollIntoView({ block: 'nearest' });
  }

  private setSectionOpen(view: ViewId, isOpen: boolean): void {
    const wrap = document.getElementById('sb-body-' + view);
    if (wrap) wrap.hidden = !isOpen;
    document.getElementById('sb-sec-' + view)?.setAttribute('aria-expanded', String(isOpen));
    document.querySelector(`.sb-sec[data-view="${view}"]`)?.classList.toggle('is-open', isOpen);
  }

  /** Pinta el contenido de una sección con los mismos renders de siempre. */
  private renderSection(view: ViewId): void {
    const host = this.hostFor(view);
    if (!host) return;
    const body = host.body;
    switch (view) {
      case 'agent':
        void this.renderSessions(body, null);
        break;
      case 'explorer':
        void this.renderFileTree(body, null);
        break;
      case 'search':
        if (!body.querySelector('#search-input')) this.renderSearch(body);
        break;
      case 'mcp':
        void this.renderMcp(body);
        break;
      case 'issues':
        body.innerHTML = '<div class="sb-sec__hint">GitHub · Gitea · GitLab · Linear · Jira Cloud. Las credenciales se gestionan en Configuración › Proveedores. El contenido externo se trata como dato no confiable.</div>';
        break;
      case 'monitor':
        void this.renderMonitorNav(body, null);
        break;
    }
  }

  private bindBottomPanel(): void {
    const content = document.getElementById('bottom-content');
    document.querySelectorAll<HTMLElement>('.panel-tab[data-bottom]').forEach((tab) => {
      tab.addEventListener('click', () => {
        document
          .querySelectorAll('.panel-tab[data-bottom]')
          .forEach((t) => t.classList.remove('is-active'));
        tab.classList.add('is-active');
        this.showSidePanel(tab.dataset.bottom || 'verification');
        // Pulsar una pestaña con el panel plegado es pedir verla: se despliega.
        const bottom = document.getElementById('panel-bottom');
        if (bottom?.dataset.collapsed === 'true') document.getElementById('btn-toggle-bottom')?.click();
      });
    });

    const panel = document.getElementById('panel-bottom');
    const toggle = document.getElementById('btn-toggle-bottom');
    if (!panel || !content) return;

    // r3: cada arranque empieza sin panel abierto. El contenido
    // solo se crea a petición y sobrevive al cierre.
    panel.dataset.collapsed = 'true';
    document.getElementById('panel-secondary')?.setAttribute('data-collapsed', 'true');
    toggle?.addEventListener('click', () => this.closeSidePanel());
    document.getElementById('btn-close-side-panel')?.addEventListener('click', () => this.closeSidePanel());
    document.addEventListener('devagents:panel-request', (event) => {
      const { kind, toggle } = (event as CustomEvent<{kind: string; toggle?: boolean}>).detail;
      const dock = document.getElementById('panel-secondary');
      if (toggle && dock?.dataset.collapsed === 'false' && dock.dataset.panel === kind) this.closeSidePanel();
      else this.showSidePanel(kind);
    });
  }

  /** Solo una orden en ejecucion abre la terminal; deltas/finales no la reabren. */
  public observeOrderEvents(events: OrderEvent[]): void {
    if (events.some(event => event.kind === 'shell_command' && eventPayload(event).status === 'running')) {
      this.showSidePanel('terminal');
    }
  }

  public closeSidePanel(): void {
    const dock = document.getElementById('panel-secondary');
    if (dock) dock.dataset.collapsed = 'true';
    document.getElementById('central-container')?.classList.remove('side-panel-open');
    const bottom = document.getElementById('panel-bottom');
    if (bottom) bottom.dataset.collapsed = 'true';
    document.querySelectorAll('.rc-tool[aria-pressed]').forEach(el => el.setAttribute('aria-pressed','false'));
  }

  public showSidePanel(kind: string): void {
    if (!['terminal','verification','engine','problems','activity','explorer'].includes(kind)) return;
    const dock = document.getElementById('panel-secondary');
    if (!dock) return;
    dock.dataset.collapsed = 'false';
    document.getElementById('central-container')?.classList.add('side-panel-open');
    dock.dataset.panel = kind;
    const isBottom = !['activity','explorer'].includes(kind);
    const bottom = document.getElementById('panel-bottom');
    if (bottom) bottom.dataset.collapsed = isBottom ? 'false' : 'true';
    const chat = document.getElementById('chat-host');
    if (chat) chat.style.display = kind === 'activity' ? 'flex' : 'none';
    const files = document.getElementById('right-explorer-body');
    if (files) files.style.display = kind === 'explorer' ? '' : 'none';
    const title = document.getElementById('side-panel-title');
    if (title) title.textContent = ({terminal:'Terminal', activity:'Actividad', explorer:'Archivos', verification:'Verificación', engine:'Salida', problems:'Problemas'} as Record<string,string>)[kind];
    document.querySelectorAll<HTMLElement>('.rc-tool').forEach(el => {
      if (['terminal','activity','explorer'].includes(el.dataset.rcAction || '')) el.setAttribute('aria-pressed', String(el.dataset.rcAction === kind));
    });
    if (kind === 'explorer' && files) void this.renderFileTree(files, null);
    if (isBottom) {
      document.querySelectorAll<HTMLElement>('.panel-tab[data-bottom]').forEach(tab => tab.classList.toggle('is-active',tab.dataset.bottom === kind));
      const content = document.getElementById('bottom-content');
      if (content) void this.renderBottom(kind, content);
    }
  }

  private async renderBottom(kind: string, host: HTMLElement): Promise<void> {
    if (kind === 'terminal') {
      // La terminal se monta una unica vez y sobrevive a los cambios de
      // pestaña: si ya existe, solo se reengancha su contenedor al DOM (el
      // proceso ConPTY y el sondeo siguen vivos aunque estuviera desmontado).
      if (this.terminal && this.terminalContainer) {
        if (this.terminalContainer.parentElement !== host) {
          host.innerHTML = '';
          host.appendChild(this.terminalContainer);
        }
        await this.terminalReady;
        return;
      }
      const wrap = document.createElement('div');
      wrap.style.height = '100%';
      wrap.style.minHeight = '0';
      host.innerHTML = '';
      host.appendChild(wrap);
      this.terminalContainer = wrap;
      this.terminal = new XtermTerminal(wrap, this.core);
      this.terminalReady = (async () => {
        const root = this.treeRoot || (await this.core.listDir('').then((r) => r.root).catch(() => ''));
        await this.terminal!.start(root);
      })();
      await this.terminalReady;
      return;
    }

    if (kind === 'engine') {
      // Este panel es el DESTINO de lo que se sacó del chat: la corriente del
      // modelo y la traza cruda de eventos. Antes solo repetía el estado del
      // motor, que ya está en la barra inferior y en Monitor.
      host.innerHTML = '<div class="subtle">Consultando estado del motor…</div>';
      try {
        const st = await this.core.status();
        host.innerHTML =
          [
            line('Núcleo C-ABI', st.engineReady ? 'inicializado' : `no inicializado — ${st.initError}`),
            line('Versión', formatEngineVersion(st.version)),
            line('Modelo de planificación', st.activeModel),
          ].join('') + `<div id="engine-output" class="col" style="gap:10px;margin-top:10px"></div>`;
        this.paintEngineOutput();
      } catch (e) {
        host.innerHTML = `<div style="color:var(--danger)">No se pudo consultar el motor: ${esc(String(e))}</div>`;
      }
      return;
    }

    if (kind === 'problems') {
      host.innerHTML = '<div class="subtle">Comprobando estado de proveedores…</div>';
      try {
        const st = await this.core.status();
        const statics: string[] = [];
        if (!st.engineReady)
          statics.push(`El núcleo no se inicializó: ${st.initError || 'motivo desconocido'}`);
        if (st.keyCount === 0)
          statics.push('No hay ninguna clave API registrada: el agente no puede llamar a ningún modelo.');
        const info = await this.core.catalogInfo().catch(() => null);
        if (info && info.model_count === 0)
          statics.push('El catálogo no tiene modelos. Ejecuta "Descubrir modelos" en Configuración.');

        // P3: los fallos de la ÚLTIMA orden. Antes este tab no veía la orden
        // que acababa de fallar ("no sirvió: empty" no llegaba a ningún
        // diagnóstico); ahora la síntesis del centro de mando viaja en el
        // mismo custom event de la salida del motor.
        const deLaOrden = this.engineOutput.problemas;

        const filas: string[] = [];
        for (const p of deLaOrden) filas.push(safeHtml`<div class="row" style="gap:8px;padding:3px 0;color:var(--danger)">${raw(icons.alert(13))}<span>${p}</span></div>`.value);
        for (const p of statics) filas.push(safeHtml`<div class="row" style="gap:8px;padding:3px 0;color:var(--warning)">${raw(icons.alert(13))}<span>${p}</span></div>`.value);
        host.innerHTML = filas.length
          ? filas.join('')
          : `<div class="row" style="gap:8px;color:var(--success)">${icons.check(13)}<span>Sin problemas detectados.</span></div>`;
      } catch (e) {
        host.innerHTML = `<div style="color:var(--danger)">${esc(String(e))}</div>`;
      }
      return;
    }

    // Verificación: ledger de auditoría append-only del motor.
    host.innerHTML = '<div class="subtle">Leyendo ledger de auditoría…</div>';
    try {
      const [rows, checklist] = await Promise.all([
        this.core.ledger() as Promise<Array<Record<string, unknown>>>,
        this.core.auditChecklist() as Promise<Array<Record<string, unknown>>>,
      ]);
      if (!rows.length && !checklist.length) {
        host.innerHTML =
          '<div class="subtle">El ledger está vacío. Cada verificación de una orden dejará aquí una entrada inmutable.</div>';
        return;
      }
      // Estado derivado por pieza (máquina pending→built→audited→verified|
      // reopened): la auditoría solo cuenta si la firmó un modelo distinto del
      // constructor. chain_broken = ledger manipulado.
      const statusColor: Record<string, string> = {
        verified: 'var(--success)',
        audited: 'var(--accent)',
        built: 'var(--fg-muted)',
        reopened: 'var(--danger)',
        pending: 'var(--warning)',
        chain_broken: 'var(--danger)',
      };
      const checklistHtml = checklist.length
        ? `<div class="subtle" style="margin:4px 0 6px">Estado de verificación por pieza (derivado del ledger):</div>` +
          checklist
            .map((s) => {
              const st = String(s.status ?? 'pending');
              const color = statusColor[st] ?? 'var(--fg-muted)';
              const auditors = Array.isArray(s.auditors) ? (s.auditors as string[]).join(', ') : '';
              return `<div class="row" style="gap:10px;padding:2px 0">
                <span style="color:${color};min-width:78px">[${esc(st)}]</span>
                <span class="subtle" style="min-width:110px">orden ${esc(String(s.order_id ?? 0))} · ${esc(String(s.subject_kind ?? ''))} #${esc(String(s.subject_id ?? ''))}</span>
                <span class="truncate subtle">${esc(
                  s.status === 'chain_broken'
                    ? 'cadena de hashes rota — ledger no confiable'
                    : `construye: ${String(s.builder || '—')}${auditors ? ` · audita: ${auditors}` : ''}`,
                )}</span>
              </div>`;
            })
            .join('') +
          '<div class="subtle" style="margin:8px 0 4px">Asientos:</div>'
        : '';
      host.innerHTML = checklistHtml + rows
        .slice(-200)
        .map((r) => {
          const verdict = String(r.verdict ?? '');
          const color =
            verdict.toUpperCase() === 'PASS'
              ? 'var(--success)'
              : verdict.toUpperCase() === 'FAIL'
                ? 'var(--danger)'
                : 'var(--fg-muted)';
          return `<div class="row" style="gap:10px;padding:2px 0">
            <span style="color:${color};min-width:46px">[${esc(verdict || '—')}]</span>
            <span class="subtle" style="min-width:120px">${esc(String(r.action ?? ''))}</span>
            <span class="truncate">${esc(String(r.model_id ?? r.provider ?? ''))}</span>
          </div>`;
        })
        .join('');
    } catch (e) {
      host.innerHTML = `<div style="color:var(--danger)">${esc(String(e))}</div>`;
    }
  }

  /**
   * Lleva el área central al editor de código. Lo llama quien ABRE un archivo,
   * no quien navega: elegir un archivo sí es motivo para cambiar de contexto.
   */
  /** Última salida cruda publicada por el centro de mando. */
  private engineOutput: { stream: string; traza: SafeHtml; problemas: string[] } = {
    stream: '',
    traza: asSafeHtml(''),
    problemas: [],
  };

  /**
   * Acumula la salida del motor aunque la pestaña no esté a la vista: si solo
   * se guardara al mirarla, abrir el panel a mitad de una orden mostraría un
   * hueco en vez de lo ocurrido. `problemas` es la síntesis de fallos de la
   * orden (P3), que el tab Problemas pinta además del estado estático.
   */
  private listenEngineOutput(): void {
    document.addEventListener('devagents:engine-output', (e) => {
      const d = (e as CustomEvent).detail as { stream?: unknown; traza?: unknown; problemas?: unknown };
      this.engineOutput = {
        stream: String(d?.stream || ''),
        // El productor publica `SafeHtml`, no HTML crudo: aquí no se inserta
        // nada sin pasar por el escape por defecto (asSafeHtml).
        traza: asSafeHtml(d?.traza),
        problemas: Array.isArray(d?.problemas) ? (d.problemas as string[]) : [],
      };
      this.paintEngineOutput();
    });
  }

  private paintEngineOutput(): void {
    const host = document.getElementById('engine-output');
    if (!host) return;
    const { stream, traza, problemas } = this.engineOutput;
    if (!stream && !traza.value && !problemas.length) {
      setHtml(host, safeHtml`<div class="subtle">Sin salida todavía. Lanza una orden y aparecerá aquí.</div>`);
      return;
    }
    setHtml(host, safeHtml`${problemas.length
        ? safeHtml`<div class="col" style="gap:4px">
             <span class="section-label">Problemas de la orden</span>
             ${joinHtml(problemas.map((pr) =>
               safeHtml`<div class="row" style="gap:8px;padding:2px 0;color:var(--danger)">${raw(icons.alert(13))}<span>${pr}</span></div>`
             ))}
           </div>`
        : ''}${stream
      ? safeHtml`<div class="col" style="gap:4px">
           <span class="section-label">Corriente del modelo</span>
           <pre class="code-surface" style="margin:0;padding:8px 10px;max-height:220px;overflow:auto;white-space:pre-wrap;word-break:break-word;font-size:11px">${stream}</pre>
         </div>`
      : ''}${traza.value
      ? safeHtml`<div class="col" style="gap:4px">
           <span class="section-label">Traza de eventos</span>
           <div class="code-surface" style="padding:8px 10px;max-height:260px;overflow:auto;font-size:11px">${traza}</div>
         </div>`
      : ''}`);
  }

  /**
   * Lanza un comando en la terminal integrada, dejándola a la vista.
   *
   * La terminal se monta de forma perezosa, así que hay que asegurarse de que
   * existe antes de escribirle. Devuelve false si no se pudo, para que quien
   * llame lo diga en vez de fingir que se ejecutó.
   */
  public async runInTerminal(command: string): Promise<boolean> {
    this.showSidePanel('terminal');
    await this.terminalReady;

    for (let i = 0; i < 25 && !this.terminal; i++) {
      await new Promise((r) => setTimeout(r, 100));
    }
    if (!this.terminal) return false;
    return this.terminal.runCommand(command);
  }

  public showEditor(): void {
    (Object.keys(this.panes) as Array<keyof PaneRefs>).forEach((k) => {
      const el = this.panes[k];
      if (el) el.style.display = k === 'editor' ? '' : 'none';
    });
    this.emitView('explorer');
  }

  /**
 * Última vista ANUNCIADA con `devagents:view-changed`. 8-nov (bug visto por
 * el propietario): showEditor anunciaba «explorer» sin cambiar `current`, así que
   * al volver al chat show('agent') no veía cambio, no lo anunciaba y las
   * ventanas de la derecha (que escuchan ese evento) se quedaban ocultas hasta
   * pasar por Dev y volver a Agente. Se compara con lo anunciado, no con current.
   */
  private emittedView: string = 'agent';

  private emitView(view: string): void {
    if (view === (this.emittedView ?? 'agent')) return;
    this.emittedView = view;
    // 10-nov: la raíz sabe qué vista se ve (el CSS oculta la franja de
    // pestañas en Configuración) y la vista entra en el historial.
    if (typeof document !== 'undefined' && document.documentElement) document.documentElement.dataset.view = view;
    this.recordHistory(view);
    document.dispatchEvent(new CustomEvent('devagents:view-changed', { detail: view }));
  }

  // ------------------------------------------------ Atrás / Avanzar (10-nov)
  /**
   * Historial de vistas como el de VS Code o Cursor: «explorer» representa el
   * editor abierto (showEditor) y el resto son las vistas del router.
   */
  private navHistory: string[] = ['agent'];
  private navPos = 0;
  private navigating = false;

  private recordHistory(view: string): void {
    // Un router creado sin constructor (pruebas con Object.create) no tiene
    // los campos inicializados: el historial nunca debe romper show().
    if (!Array.isArray(this.navHistory)) {
      this.navHistory = ['agent'];
      this.navPos = 0;
    }
    if (this.navigating) return;
    if (this.navHistory[this.navPos] === view) return;
    this.navHistory = this.navHistory.slice(0, this.navPos + 1);
    this.navHistory.push(view);
    if (this.navHistory.length > 50) this.navHistory.shift();
    this.navPos = this.navHistory.length - 1;
    this.syncNavButtons();
  }

  private goTo(view: string): void {
    this.navigating = true;
    try {
      if (view === 'explorer' && this.current !== 'explorer') this.showEditor();
      else this.show(view as ViewId);
    } finally {
      this.navigating = false;
    }
    this.syncNavButtons();
  }

  public canGoBack(): boolean { return this.navPos > 0; }
  public canGoForward(): boolean { return this.navPos < this.navHistory.length - 1; }

  public back(): void {
    if (!this.canGoBack()) return;
    this.navPos--;
    this.goTo(this.navHistory[this.navPos]);
  }

  public forward(): void {
    if (!this.canGoForward()) return;
    this.navPos++;
    this.goTo(this.navHistory[this.navPos]);
  }

  /** Cierra Configuración y vuelve a la última vista que no lo era. */
  public closeSettings(): void {
    for (let i = this.navPos - 1; i >= 0; i--) {
      if (this.navHistory[i] !== 'settings') {
        this.navPos = i;
        this.goTo(this.navHistory[i]);
        return;
      }
    }
    this.show('agent');
  }

  private syncNavButtons(): void {
    if (typeof document === 'undefined') return;
    const back = document.getElementById('btn-nav-back') as HTMLButtonElement | null;
    const fwd = document.getElementById('btn-nav-forward') as HTMLButtonElement | null;
    if (back) back.disabled = !this.canGoBack();
    if (fwd) fwd.disabled = !this.canGoForward();
  }

  /** Selecciona una vista: marca el icono, cambia el panel central y repinta la barra lateral. */
  public show(view: ViewId): void {
    // `view-changed` solo se emite cuando la vista CAMBIA de verdad. Antes se
    // disparaba en cada llamada —incluidas las de `show(current)` desde
    // refresh() o desde abrir una sesión ya estando en la vista de agente— y
    // cada emisión arrastraba un refreshStatus() del centro de mando: al
    // pulsar una sesión se veía la barra "verificándose" porque eran cinco
    // llamadas al motor (status, providers y los tres pines de modelo).
    const changed = view !== this.current;
    this.current = view;
    this.emitView(view);

    document.querySelectorAll<HTMLElement>('.activity-bar__item').forEach((el) => {
      el.classList.toggle('is-active', el.dataset.view === view);
    });

    // El Explorador y la Búsqueda son NAVEGADORES: cambian lo que hay en la
    // barra lateral y nada más. Antes también arrastraban el área central al
    // editor, así que pulsar la lupa te sacaba de la conversación y te metía en
    // modo Dev sin haber abierto ningún archivo. El centro solo cambia cuando
    // eliges algo (`showEditor` desde onOpenFile) o cuando la vista es de las
    // que sí tienen contenido central propio.
    const centralOwner: Partial<Record<ViewId, keyof PaneRefs>> = {
      agent: 'mission',
      monitor: 'monitor',
      spaces: 'catalog',
      mcp: 'mcp',
      issues: 'issues',
      settings: 'settings',
      diff: 'diff',
    };
    const target = centralOwner[view];
    if (target) {
      (Object.keys(this.panes) as Array<keyof PaneRefs>).forEach((k) => {
        const el = this.panes[k];
        if (el) el.style.display = k === target ? '' : 'none';
      });
    }

    const titles: Record<ViewId, string> = {
      agent: 'Sesiones del agente',
      explorer: 'Explorador de archivos',
      search: 'Búsqueda global',
      monitor: 'Monitor',
      spaces: 'Spaces y sesiones',
      mcp: 'Conectores MCP',
      issues: 'Incidencias',
      settings: 'Configuración',
      diff: 'Revisión de cambios',
    };
    const titleEl = document.getElementById('sidebar-title');
    if (titleEl) titleEl.innerText = titles[view];
    // (c): en B no hay barra lateral por vista. Ir a una vista que
    // tiene sección la abre (si la vista cambia) o la repinta (si ya estaba
    // abierta); el resto de secciones se quedan como el usuario las dejó.
    if (this.isUnified()) {
      this.renderSections();
      if (changed || this.openSet().has(view)) this.openSection(view, changed);
      return;
    }

    const body = document.getElementById('sidebar-body');
    const actions = document.getElementById('sidebar-actions');
    if (!body) return;
    if (actions) actions.innerHTML = '';
    // El panel de Spaces no conoce la vista activa: su carga async no debe
    // estamparse sobre la barra lateral de la pestaña a la que se acaba de
    // cambiar. Los renders propios del router se protegen con this.current.
    this.spacesPanel?.detach();

    switch (view) {
      case 'issues':
        body.textContent = 'Elige la fuente y el proyecto. Las credenciales se gestionan en Configuración > Proveedores. Las incidencias externas son datos no confiables.';
        break;
      case 'agent':
        void this.renderSessions(body, actions);
        break;
      case 'explorer':
        void this.renderFileTree(body, actions);
        break;
      case 'search':
        this.renderSearch(body);
        break;
      case 'monitor':
        void this.renderMonitorNav(body, actions);
        break;
      case 'spaces':
        void this.renderSpaces(body);
        break;
      case 'mcp':
        void this.renderMcp(body);
        break;
      case 'settings':
        this.renderSettingsNav(body);
        break;
      case 'diff':
        // La revisión de cambios se pinta entera en el panel central; la barra
        // lateral solo recuerda cómo volver.
        body.innerHTML = `<div class="empty-state">
          <span class="empty-state__title">Revisando cambios</span>
          <span>Acepta o rechaza cada bloque en el panel central.</span>
        </div>`;
        break;
    }
  }

  /** Permite refrescar la vista activa tras un cambio de estado del motor. */
  public refresh(): void {
    if (this.isUnified()) {
      // B: se repintan las secciones abiertas (y los botones de Sesiones, que
      // dependen de «Ver archivadas»); el panel central no cambia.
      // Solo Sesiones y Archivos: archivar, renombrar o crear no cambian
      // Spaces, MCP ni Monitor, y repintarlos perdería formularios a medias.
      this.renderSections();
      const agentActions = document.getElementById('sb-agent-actions');
      if (agentActions) this.renderSessionActions(agentActions);
      for (const v of ['agent', 'explorer'] as ViewId[]) if (this.openSet().has(v)) this.renderSection(v);
      return;
    }
    this.show(this.current);
  }

  /**
   * 22-09: repinta SOLO la lista de sesiones, si es la vista activa. La orden
   * nueva no aparecía en la barra hasta pulsar «Actualizar» (medido con la
   * #753). No pasa por show(): eso emite view-changed y mueve otros paneles.
   */
  public refreshSessions(): void {
    const host = this.hostFor('agent');
    if (!host) return;
    void this.renderSessions(host.body, host.actions);
  }

  // --- Contenidos de la barra lateral --------------------------------------

  /** Botones de Sesiones: «+» (solo A), «Archivo» con su menú. */
  private renderSessionActions(actions: HTMLElement): void {
    // "Nueva conversación" vive aquí, junto a la lista de sesiones, y no solo
    // dentro del hilo: una vez empezada una charla no había forma de romperla
    // sin reiniciar la aplicación.
    //
    // el historial se acumula y se ARCHIVA (nunca se borra). El
    // botón de la caja archiva lo anterior a una fecha con confirmación, y el
    // interruptor «Ver archivadas» cambia la lista a lo archivado, donde cada
    // fila ofrece «Restaurar». Los tres son iconos discretos junto a los de
    // siempre, no botones nuevos con otro estilo.
    //
    // (c), maqueta v2 aprobada: los dos de archivo van en UN solo
    // botón «Archivo» con su menú, y no hay «Actualizar» (la lista se
    // revalida sola al enviar, al cambiar de vista y al terminar una orden).
    // En B «Nueva conversación» ya está en la barra de pestañas y aquí se
    // oculta por CSS; en A se queda como estaba.
    const archLabel = this.showArchived ? 'Volver a las sesiones activas' : 'Ver archivadas';
    actions.innerHTML =
      `<button class="icon-btn" id="sb-new-chat" title="Nueva conversación (rompe el hilo actual)">${icons.plus(14)}</button>` +
      `<span class="sb-amenu">` +
      `<button class="icon-btn${this.showArchived ? ' is-active' : ''}" id="sb-archive-menu" title="Archivo" aria-label="Archivo" aria-haspopup="menu" aria-expanded="false" aria-controls="sb-archive-pop">${icons.archive(14)}</button>` +
      `<span class="sb-amenu__pop" id="sb-archive-pop" role="menu" aria-label="Archivo" hidden>` +
      `<button class="sb-amenu__item" id="sb-archive-before" role="menuitem">${icons.archive(13)}<span>Archivar historial anterior…</span></button>` +
      `<button class="sb-amenu__item${this.showArchived ? ' is-active' : ''}" id="sb-show-archived" role="menuitemcheckbox" aria-checked="${this.showArchived}" aria-pressed="${this.showArchived}" title="${archLabel}">${icons.unarchive(13)}<span>${archLabel}</span></button>` +
      `</span></span>`;
    const menuBtn = actions.querySelector<HTMLElement>('#sb-archive-menu');
    const pop = actions.querySelector<HTMLElement>('#sb-archive-pop');
    const closeMenu = (focusBtn = false): void => {
      if (!pop || pop.hidden) return;
      pop.hidden = true;
      menuBtn?.setAttribute('aria-expanded', 'false');
      document.removeEventListener('pointerdown', onOutside, true);
      document.removeEventListener('keydown', onKey, true);
      if (focusBtn) menuBtn?.focus();
    };
    const onOutside = (ev: Event): void => {
      if (!(ev.target as Node | null) || !actions.querySelector('.sb-amenu')?.contains(ev.target as Node)) closeMenu();
    };
    const onKey = (ev: KeyboardEvent): void => {
      if (ev.key === 'Escape') {
        ev.stopPropagation();
        closeMenu(true);
      } else if (ev.key === 'Tab') {
        closeMenu();
      }
    };
    menuBtn?.addEventListener('click', () => {
      if (!pop) return;
      if (!pop.hidden) {
        closeMenu();
        return;
      }
      pop.hidden = false;
      menuBtn.setAttribute('aria-expanded', 'true');
      document.addEventListener('pointerdown', onOutside, true);
      document.addEventListener('keydown', onKey, true);
      pop.querySelector<HTMLElement>('.sb-amenu__item')?.focus();
    });
    pop?.querySelectorAll('.sb-amenu__item').forEach((item) => item.addEventListener('click', () => closeMenu()));
    actions.querySelector('#sb-new-chat')?.addEventListener('click', () => {
      // El hook ya lleva a la vista de agente (router.show('agent')),
      // que revalida la lista en silencio. El refresh() extra que había
      // aquí lanzaba una SEGUNDA petición idéntica al motor por cada clic.
      this.hooks.onNewConversation?.();
    });
    actions.querySelector('#sb-show-archived')?.addEventListener('click', () => {
      this.showArchived = !this.showArchived;
      // La caché es del modo anterior: se descarta para no enseñar lo que no
      // toca mientras llega la lista del modo nuevo.
      this.sessionsCache = [];
      this.refresh();
    });
    actions.querySelector('#sb-archive-before')?.addEventListener('click', () => {
      void this.archiveBeforeFlow();
    });
  }

  private async renderSessions(body: HTMLElement, actions: HTMLElement | null): Promise<void> {
    if (actions) this.renderSessionActions(actions);

    // Cache-first: la lista ya cargada se pinta al instante y el motor solo
    // REVALIDA en silencio. Antes cada entrada a esta vista —incluido pulsar
    // una sesión— borraba la lista con «Cargando sesiones…» y esperaba la
    // respuesta, que es lo que el usuario percibía como «se pone a
    // actualizarse» cada vez que tocaba algo. El mensaje de carga solo
    // aparece cuando de verdad no hay nada que mostrar.
    if (this.sessionsCache.length) {
      this.paintSessions(body, this.sessionsCache);
    } else {
      body.innerHTML = '<div class="subtle" style="padding:8px">Cargando sesiones…</div>';
    }

    // Coalesce de la revalidación: dos llamadas seguidas (p. ej. abrir sesión +
    // volver a la vista) comparten la misma petición en vez de lanzar dos, y
    // una que llegue mientras hay otra en vuelo queda encolada (una sola) y
    // corre al terminar. Así el refresco de la orden recién enviada no se cae.
    this.sessionsRefresher.request();
  }

  /**
   * Revalidación real de la lista (la ejecuta `sessionsRefresher`, que evita
   * lecturas concurrentes y encola una pendiente en vez de perderla).
   */
  private async revalidateSessions(): Promise<void> {
    const prevSignature = sesionesSignature(this.sessionsCache);
    try {
      // el interruptor decide qué pide la barra al motor. Aun así
      // `paintSessions` vuelve a filtrar: la lista puede llegar de una caché
      // del modo anterior mientras el interruptor acaba de cambiar.
      const sessions = await this.core.listSessions(this.showArchived ? 'archived' : 'active');
      // Si el usuario ya se fue a otra vista, el body es de otro panel: se
      // actualiza la caché igualmente y no se toca el DOM ajeno.
      this.sessionsCache = sessions;
      // (c): en B la lista vive en la sección Sesiones (abierta).
      const host = this.hostFor('agent');
      if (!host) return;
      const body = host.body;
      if (sesionesSignature(sessions) !== prevSignature || !body.querySelector('.sess-search')) {
        // El segundo caso cubre el body que quedó en «Cargando sesiones…» o
        // con un error previo: hay que repintarlo aunque la firma coincida.
        this.paintSessions(body, sessions);
      }
    } catch (e) {
      const host = this.hostFor('agent');
      if (host && !this.sessionsCache.length) {
        const body = host.body;
        body.innerHTML = `<div class="empty-state" style="color:var(--danger)">${esc(String(e))}</div>`;
      }
    }
  }

/**
   * S8 — la lista de sesiones deja de ser una pared.
   *
   * Con 215 órdenes acumuladas, la barra lateral era una sucesión de cuarenta
   * filas casi idénticas («Crea una pagina web…», «Crea una pagina web…») sin
   * forma de buscar, de saber cuál era de hoy, ni de quitar ninguna. Encontrar
   * una conversación pasada era desplazarse y adivinar.
   *
   * Tres cosas, ninguna sofisticada: filtro por texto, agrupación por fecha, y
   * borrar. El filtro se aplica sobre la lista YA cargada —sin volver al
   * motor— porque el coste está en la lectura, no en el filtrado, y así escribir
   * responde a cada tecla.
   */
  private sessionFilter = '';
  /** E2.11 — filtro por categoría: '' = todas, '__none__' = solo sin categoría. */
  private sessionCatFilter = '';
  /** — interruptor «Ver archivadas»: false = historial activo. */
  private showArchived = false;
  /** Última lista traída del motor: el filtro se aplica sobre ella, no sobre la BD. */
  private sessionsCache: SessionInfo[] = [];
  /**
   * P3 (corrección auditoría): revalidación de la lista con coalescing. Una
   * lectura en vuelo más, como máximo, una pendiente: el refresco posterior a
   * `submitOrder` ya no se pierde por coincidir con el de la fase `planning`.
   */
  private sessionsRefresher!: RefreshCoalescer;

  private paintSessions(body: HTMLElement, sessions: SessionInfo[]): void {
    // La repinta reemplaza el innerHTML, así que el scroll de la lista se
    // perdería si no se conserva: abrir una sesión o una revalidación en
    // segundo plano no debe mover lo que el usuario está mirando.
    const scrollTop = body.scrollTop;
    const filtro = this.sessionFilter.trim().toLowerCase();
    const catsAhora = sessionCats();
    const catSel = this.sessionCatFilter;
    const visibles = sessions.filter((s) => {
      const id = Number(s.order_id ?? s.id ?? 0);
      // sin el interruptor, el historial activo; con él, lo
      // archivado. La regla vive en `visibleEnBarra` para poder probarla.
      if (!visibleEnBarra(s, this.showArchived)) return false;
      if (filtro && !coincideBusqueda(String(s.title || `Orden ${id}`), id, filtro)) return false;
      // E2.11 — filtro de categoría: '' pasa todo, '__none__' solo las sin
      // etiqueta, y una etiqueta solo sus sesiones.
      if (!catSel) return true;
      const cat = catsAhora[String(id)] || '';
      return catSel === '__none__' ? !cat : cat === catSel;
    });

    const buscador =
      `<div class="sess-search">` +
      `<label class="sess-search__field"><span class="sess-search__ico" aria-hidden="true">${icons.search(12)}</span>` +
      `<input id="sb-sess-filter" type="text" placeholder="Buscar sesión…" aria-label="Buscar sesión" value="${escapeAttribute(this.sessionFilter)}" />` +
      `<select id="sb-sess-cat" title="Filtrar por categoría" aria-label="Filtrar por categoría">` +
      `<option value="">Todas las categorías</option>` +
      SESSION_CATEGORIES.map(
        (c) => `<option value="${escapeAttribute(c)}" ${this.sessionCatFilter === c ? 'selected' : ''}>${esc(c)}</option>`
      ).join('') +
      `<option value="__none__" ${this.sessionCatFilter === '__none__' ? 'selected' : ''}>Sin categoría</option>` +
      `</select></label>` +
      `</div>`;

    // Sin ninguna sesión el mensaje no es «no coincide el filtro» sino que
    // todavía no se ha abierto ninguna conversación (o, con el interruptor,
    // que aún no hay nada archivado).
    if (!sessions.length) {
      body.innerHTML = this.showArchived
        ? `<div class="empty-state">
        ${icons.archive(22)}
        <span class="empty-state__title">Sin sesiones archivadas</span>
        <span>Las que archives aparecerán aquí, listas para restaurar.</span>
      </div>`
        : `<div class="empty-state">
        ${icons.sessions(22)}
        <span class="empty-state__title">Sin sesiones todavía</span>
        <span>Escribe una orden en el compositor para abrir la primera.</span>
      </div>`;
      return;
    }

    if (!visibles.length) {
      body.innerHTML =
        buscador +
        (this.showArchived
          ? `<div class="subtle" style="padding:10px 8px">No hay sesiones archivadas que coincidan${this.sessionFilter ? ` con «${esc(this.sessionFilter)}»` : ''}.</div>`
          : `<div class="subtle" style="padding:10px 8px">Ninguna sesión coincide con «${esc(this.sessionFilter)}».</div>`);
      this.bindSessionFilter(body);
      return;
    }

    // Colapsar el hilo antes de asignarlo a la fecha de su orden más reciente.
    // Una conversación que cruza varios días sigue teniendo una sola fila.
    const filasPorHilo = agruparPorConversacion(ordenarPorReciente(visibles));
    const grupos = new Map<string, typeof filasPorHilo>();
    for (const fila of filasPorHilo) {
      const g = grupoPorFecha(Number(fila.cabeza.created_at ?? 0));
      const lista = grupos.get(g);
      if (lista) lista.push(fila);
      else grupos.set(g, [fila]);
    }

    let html = buscador;
    const cats = sessionCats();
    // E2.5 — las órdenes 'planned' huérfanas se ven PRIMERO: son trabajo que
    // espera una decisión del usuario, no historial. Cada una se puede
    // retomar (clic → tarjeta de aprobación) o descartar (la × de siempre).
    // Solo los planes de las últimas 24 h (planPendienteVigente): los viejos
    // se quedan en su día con la marca neutra «plan sin aprobar».
    const pendientes = filasPorHilo.filter(({ cabeza }) =>
      planPendienteVigente(String(cabeza.status_text ?? cabeza.status ?? ''), Number(cabeza.created_at ?? 0))
    );
    // (c), maqueta v2: cada grupo es plegable (▾/▸). Como en la
    // maqueta, por defecto solo se abren «Esperan tu aprobación» y «Hoy»; los
    // anteriores arrancan plegados para que el resto de secciones se vea. Lo
    // que el usuario pliegue o despliegue se recuerda por título de grupo.
    const plegados = sessGroupState();
    const grupoHtml = (clave: string, titulo: string, n: number, filasHtml: string, pendiente: boolean): string => {
      // Con un filtro puesto, los grupos que tienen coincidencias se abren:
      // si no, la búsqueda parecería vacía.
      const filtrando = !!this.sessionFilter.trim() || !!this.sessionCatFilter;
      const abierto = filtrando || (clave in plegados ? !plegados[clave] : pendiente || clave === 'Hoy');
      return `<div class="sess-group${pendiente ? ' sess-group--pending' : ''}" data-group="${escapeAttribute(clave)}">` +
        `<button type="button" class="sess-group__head section-label${pendiente ? ' section-label--pending' : ''}" aria-expanded="${abierto}">${esc(titulo)} · ${n}</button>` +
        `<div class="sess-group__rows"${abierto ? '' : ' hidden'}>${filasHtml}</div></div>`;
    };
    if (pendientes.length) {
      html += grupoHtml(
        '__pendientes__',
        'Esperan tu aprobación',
        pendientes.length,
        pendientes.map(({ cabeza, cuantas }) => this.sessRowHtml(cabeza, cuantas, cats, true)).join(''),
        true
      );
    }
    // Las pendientes ya salieron en su sección: repetirlas en el grupo de
    // fecha las mostraría dos veces.
    const idsPendientes = new Set(pendientes.map(({ cabeza }) => Number(cabeza.order_id ?? cabeza.id ?? 0)));
    for (const [titulo, filas] of grupos) {
      const listado = idsPendientes.size
        ? filas.filter(({ cabeza }) => !idsPendientes.has(Number(cabeza.order_id ?? cabeza.id ?? 0)))
        : filas;
      if (!listado.length) continue;
      html += grupoHtml(
        titulo,
        titulo,
        listado.length,
        listado.map(({ cabeza, cuantas }) => this.sessRowHtml(cabeza, cuantas, cats, false)).join(''),
        false
      );
    }
    body.innerHTML = html;
    body.scrollTop = scrollTop;
    body.querySelectorAll<HTMLElement>('.sess-group__head').forEach((head) => {
      head.addEventListener('click', () => {
        const grupo = head.closest<HTMLElement>('.sess-group');
        const filas = grupo?.querySelector<HTMLElement>('.sess-group__rows');
        if (!grupo || !filas) return;
        const abrir = filas.hidden;
        filas.hidden = !abrir;
        head.setAttribute('aria-expanded', String(abrir));
        const estado = sessGroupState();
        estado[grupo.dataset.group || ''] = !abrir;
        saveSessGroupState(estado);
      });
    });
    this.bindSessionFilter(body);
    this.bindSessionRows(body);
  }

  /**
   * E2.5/E2.11 — una fila de sesión: nombre, estado, badge «por aprobar» si
   * espera decisión, categoría persistente, fork y borrar.
   */
  private sessRowHtml(
    cabeza: SessionInfo,
    cuantas: number,
    cats: Record<string, string>,
    porAprobar: boolean
  ): string {
    const id = Number(cabeza.order_id ?? cabeza.id ?? 0);
    const nombre = String(cabeza.title || `Orden ${id}`);
    const insignia =
      cuantas > 1
        ? safeHtml`<span class="badge" title="${cuantas} peticiones en este hilo">${cuantas}</span>`
        : '';
    const cat = cats[String(id)] || '';
    const estadoTexto = cabeza.status_text ?? cabeza.status;
    const estado = estadoDeSesion(estadoTexto, cabeza.delegated, cabeza.integrated);
    const sinIntegrar = delegacionIncompleta(cabeza.delegated, cabeza.integrated);
    // una archivada ofrece volver; una activa terminal, salir del
    // historial sin borrarse. Las que aún trabajan no se pueden archivar.
    const archivada = Number(cabeza.archived_at ?? 0) > 0;
    const accionArchivo = archivada
      ? safeHtml`<button class="icon-btn sess-archive" data-restore="${id}" title="Restaurar: vuelve al historial de sesiones activas">${raw(icons.unarchive(12))}</button>`
      : esArchivable(estadoTexto)
        ? safeHtml`<button class="icon-btn sess-archive" data-archive="${id}" title="Archivar: sale del historial sin borrarse (se puede restaurar)">${raw(icons.archive(12))}</button>`
        : '';
    return safeHtml`<div class="list-item sess-row${porAprobar ? ' sess-row--pending' : ''}" data-order="${id}" data-conversation="${String(cabeza.conversation_id ?? '')}" title="${nombre}">
      <span class="sess-dot sess-dot--${sinIntegrar && !/fail/i.test(String(estadoTexto ?? '')) ? 'warn' : sessDotClass(String(estadoTexto ?? ''), porAprobar)}" aria-hidden="true"></span>
      <span class="list-item__label">${nombre}</span>
      ${insignia}
      ${porAprobar ? raw('<span class="badge badge--pending" title="Plan propuesto en las últimas 24 h: ábrelo para aprobarlo o descartarlo">por aprobar</span>') : ''}
      ${cat ? safeHtml`<span class="sess-cat" data-cat-menu="${id}" title="Categoría (clic para cambiar)">${cat}</span>` : raw(`<span class="sess-cat sess-cat--none" data-cat-menu="${id}" title="Asignar categoría" aria-label="Asignar categoría">${icons.plus(11)}</span>`)}
      <span class="list-item__meta">${estado}</span>
      ${accionArchivo}
      <button class="icon-btn sess-fork" data-fork="${id}" title="Fork: conversación nueva que hereda el contexto de esta sesión">${raw(icons.fork(12))}</button>
      <button class="sess-del" data-del="${id}" title="Descartar: borra esta sesión y su historial" aria-label="Descartar sesión">${raw(icons.close(11))}</button>
    </div>`.value;
  }

  private bindSessionRows(body: HTMLElement): void {
    body.querySelectorAll<HTMLElement>('.sess-row').forEach((el) => {
      el.addEventListener('click', (ev) => {
        // El clic en la ×, en el fork, en la categoría o en archivar/restaurar
        // no abre la sesión.
        const t = ev.target as HTMLElement;
        if (
          t?.dataset?.del || t?.closest('[data-del]') ||
          t?.dataset?.fork || t?.closest('[data-fork]') ||
          t?.dataset?.catMenu || t?.closest('[data-cat-menu]') ||
          t?.closest('[data-archive]') || t?.closest('[data-restore]')
        ) return;
        const id = Number(el.dataset.order);
        if (id && this.hooks.onOpenSession) this.hooks.onOpenSession(id, el.dataset.conversation || null);
      });
    });

    // E2.11 — fork: conversación nueva con el contexto de esta sesión.
    body.querySelectorAll<HTMLElement>('[data-fork]').forEach((btn) => {
      btn.addEventListener('click', (ev) => {
        ev.stopPropagation();
        const id = Number(btn.dataset.fork);
        if (id) document.dispatchEvent(new CustomEvent('devagents:fork-session', { detail: id }));
      });
    });

    // — archivar una sesión: sale del historial activo sin borrarse.
    // No lleva confirmación porque es reversible con un clic en «Ver archivadas».
    body.querySelectorAll<HTMLElement>('[data-archive]').forEach((btn) => {
      btn.addEventListener('click', async (ev) => {
        ev.stopPropagation();
        const id = Number(btn.dataset.archive);
        if (!id) return;
        try {
          await this.core.archiveSession(id, true);
          this.refresh();
        } catch (e) {
          notice('No se pudo archivar la sesión: ' + String(e), 'error');
        }
      });
    });

    // — restaurar una archivada: vuelve al historial activo.
    body.querySelectorAll<HTMLElement>('[data-restore]').forEach((btn) => {
      btn.addEventListener('click', async (ev) => {
        ev.stopPropagation();
        const id = Number(btn.dataset.restore);
        if (!id) return;
        try {
          await this.core.archiveSession(id, false);
          this.refresh();
        } catch (e) {
          notice('No se pudo restaurar la sesión: ' + String(e), 'error');
        }
      });
    });

    // E2.11 — categoría persistente por sesión (localStorage): menú inline
    // con las cuatro opciones fijas y «Sin categoría» para quitarla.
    body.querySelectorAll<HTMLElement>('[data-cat-menu]').forEach((chip) => {
      chip.addEventListener('click', (ev) => {
        ev.stopPropagation();
        const id = chip.dataset.catMenu || '';
        this.showCategoryMenu(chip as HTMLElement, id, body);
      });
    });

    body.querySelectorAll<HTMLElement>('[data-del]').forEach((btn) => {
      btn.addEventListener('click', async (ev) => {
        ev.stopPropagation();
        const id = Number(btn.dataset.del);
        if (!id) return;
        const fila = btn.closest('.sess-row') as HTMLElement | null;
        const nombre = fila?.querySelector('.list-item__label')?.textContent ?? `Orden ${id}`;
        // Se pregunta: el borrado se lleva los mensajes y los eventos, y no
        // hay deshacer.
        const ok = await confirmModal({
          title: `¿Borrar «${nombre}»?`,
          paragraphs: [
            'Se borran también sus mensajes y su historial de eventos.',
            'No se puede deshacer.',
          ],
          confirmLabel: 'Borrar sesión',
          danger: true,
        });
        if (!ok) return;
        try {
          await this.core.deleteSession(id);
          this.refresh();
        } catch (e) {
          notice('No se pudo borrar la sesión: ' + String(e), 'error');
        }
      });
    });
  }

  private bindSessionFilter(body: HTMLElement): void {
    const input = body.querySelector<HTMLInputElement>('#sb-sess-filter');
    input?.addEventListener('input', () => {
      this.sessionFilter = input.value;
      // Se repinta desde la lista ya cargada: ni una llamada al motor por
      // tecla. Se restaura foco y cursor para que escribir no vaya a saltos.
      const pos = input.selectionStart ?? input.value.length;
      this.paintSessions(body, this.sessionsCache);
      const nuevo = body.querySelector<HTMLInputElement>('#sb-sess-filter');
      if (nuevo) {
        nuevo.focus();
        nuevo.setSelectionRange(pos, pos);
      }
    });
    body.querySelector<HTMLSelectElement>('#sb-sess-cat')?.addEventListener('change', (ev) => {
      this.sessionCatFilter = (ev.target as HTMLSelectElement).value;
      this.paintSessions(body, this.sessionsCache);
    });
  }

  /**
   * E2.11 — menú de categoría de una sesión. Se pinta junto al chip y se
   * cierra con el siguiente clic fuera; elegir una repinta la lista en el
   * acto. Las cuatro etiquetas son fijas a propósito: categorías libres
   * acaban siendo un segundo buscador mal poblado.
   */
  private showCategoryMenu(chip: HTMLElement, orderIdStr: string, body: HTMLElement): void {
    document.querySelector('.sess-cat-menu')?.remove();
    const id = Number(orderIdStr);
    if (!id) return;
    const rect = chip.getBoundingClientRect();
    const menu = document.createElement('div');
    menu.className = 'sess-cat-menu ctx-menu';
    menu.innerHTML =
      SESSION_CATEGORIES.map((c) => `<button type="button" class="ctx-menu__item" data-cat="${escapeAttribute(c)}">${esc(c)}</button>`).join('') +
      `<button type="button" class="ctx-menu__item" data-cat="">Sin categoría</button>`;
    menu.style.left = `${Math.min(rect.left, window.innerWidth - 150)}px`;
    document.body.appendChild(menu);
    // Si no cabe debajo del chip (sesiones al final de la lista), el menú se
    // abre hacia arriba: sin esta guarda los ítems quedan fuera del viewport
    // y la categoría no se puede asignar (medido en vivo 2026-09-18).
    const alto = menu.offsetHeight || 160;
    const debajo = rect.bottom + 2;
    menu.style.top = debajo + alto > window.innerHeight - 4
      ? `${Math.max(4, rect.top - alto - 2)}px`
      : `${debajo}px`;
    const close = () => menu.remove();
    setTimeout(() => {
      document.addEventListener('click', close, { once: true });
      document.addEventListener('contextmenu', close, { once: true });
    }, 0);
    menu.querySelectorAll<HTMLElement>('[data-cat]').forEach((btn) => {
      btn.addEventListener('click', (ev) => {
        ev.stopPropagation();
        setSessionCat(id, btn.dataset.cat || '');
        close();
        this.paintSessions(body, this.sessionsCache);
      });
    });
  }

  /**
 * — «Archivar historial anterior…».
   *
   * El historial acumula cientos de charlas de prueba, y archivar en masa es
   * destructivo de un vistazo si sale de un clic suelto. Por eso el flujo va en
   * DOS pasos: se elige la fecha de corte (por defecto, todo lo anterior a hoy)
   * y el motor CUENTA cuántas sesiones caerían sin tocar nada; solo entonces el
   * botón pasa a «Archivar» y, al pulsarlo, ese recuento viaja como
   * confirmación y el motor lo revalida dentro de la misma transacción. Si algo
   * cambió entre la cuenta y la escritura, no se archiva nada y pide confirmar
   * otra vez. Nunca se borra: todo esto se deshace con «Ver archivadas».
   */
  private async archiveBeforeFlow(): Promise<void> {
    const isoLocal = (d: Date): string =>
      `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
    const corteDeFecha = (valor: string): number => {
      const [y, m, d] = valor.split('-').map((n) => Number(n));
      if (!y || !m || !d) return 0;
      return Math.floor(new Date(y, m - 1, d, 0, 0, 0, 0).getTime() / 1000);
    };
    const hoy = new Date();
    hoy.setHours(0, 0, 0, 0);

    const overlay = document.createElement('div');
    overlay.style.cssText =
      'position:fixed;inset:0;z-index:9500;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;padding:24px';
    const card = document.createElement('div');
    card.setAttribute('role', 'dialog');
    card.setAttribute('aria-modal', 'true');
    card.style.cssText = [
      'max-width:460px',
      'width:100%',
      'background:var(--bg-elevated, var(--bg-panel))',
      'color:var(--text)',
      'border:1px solid var(--border)',
      'border-left:3px solid var(--accent)',
      'border-radius:10px',
      'padding:18px 20px',
      'box-shadow:0 18px 50px rgba(0,0,0,.5)',
      'display:flex',
      'flex-direction:column',
      'gap:10px',
    ].join(';');

    const h = document.createElement('div');
    h.style.cssText = 'font-weight:600;font-size:14px';
    h.textContent = 'Archivar historial anterior';
    card.appendChild(h);

    const guia = document.createElement('div');
    guia.style.cssText = 'font-size:12px;line-height:1.5;color:var(--text-muted, var(--text))';
    guia.textContent =
      'Se archivarán las sesiones anteriores a esta fecha. No se borra nada: podrás verlas y restaurarlas con «Ver archivadas».';
    card.appendChild(guia);

    const input = document.createElement('input');
    input.type = 'date';
    input.className = 'input';
    input.value = isoLocal(hoy);
    card.appendChild(input);

    const aviso = document.createElement('div');
    aviso.className = 'subtle';
    aviso.style.cssText = 'font-size:12px;min-height:16px';
    card.appendChild(aviso);

    const row = document.createElement('div');
    row.style.cssText = 'display:flex;gap:8px;margin-top:4px;justify-content:flex-end';
    const cancel = document.createElement('button');
    cancel.className = 'btn';
    cancel.textContent = 'Cancelar';
    const action = document.createElement('button');
    action.className = 'btn';
    action.textContent = 'Continuar';
    row.appendChild(cancel);
    row.appendChild(action);
    card.appendChild(row);
    overlay.appendChild(card);
    document.body.appendChild(overlay);

    let corte = 0;
    let previsto = 0;
    let listo = false;
    let cerrado = false;
    const cerrar = (): void => {
      if (cerrado) return;
      cerrado = true;
      document.removeEventListener('keydown', onKey, true);
      overlay.remove();
    };
    function onKey(ev: KeyboardEvent): void {
      if (ev.key === 'Escape') {
        ev.preventDefault();
        cerrar();
      }
    }
    document.addEventListener('keydown', onKey, true);
    cancel.addEventListener('click', () => cerrar());
    // Cambiar la fecha invalida el recuento mostrado: hay que volver a contar
    // antes de poder archivar (el segundo auditor, r2).
    input.addEventListener('input', () => {
      if (!listo && !aviso.textContent) return;
      listo = false;
      previsto = 0;
      aviso.textContent = '';
      action.textContent = 'Continuar';
      action.disabled = false;
    });
    overlay.addEventListener('click', (ev) => {
      if (ev.target === overlay) cerrar();
    });
    input.focus();

    action.addEventListener('click', async () => {
      if (cerrado) return;
      // Paso 1: contar sin escribir. Paso 2: escribir con ese recuento.
      if (!listo) {
        corte = corteDeFecha(input.value);
        if (!corte) {
          aviso.textContent = 'Elige una fecha válida.';
          return;
        }
        action.disabled = true;
        try {
          const { count } = await this.core.previewArchiveBefore(corte);
          previsto = Number(count) || 0;
          if (!previsto) {
            aviso.textContent = 'No hay sesiones anteriores que archivar.';
            action.textContent = 'Archivar';
            action.disabled = true;
            return;
          }
          aviso.textContent = `Se ${previsto === 1 ? 'archivará 1 sesión' : `archivarán ${previsto} sesiones`}. Se pueden restaurar cuando quieras.`;
          listo = true;
          action.textContent = 'Archivar';
          action.disabled = false;
          // El foco cae en Cancelar: pulsar Enter por inercia no debe archivar.
          cancel.focus();
        } catch (e) {
          action.disabled = false;
          aviso.textContent = 'No se pudo contar el historial: ' + String(e);
        }
        return;
      }
      action.disabled = true;
      try {
        await this.core.archiveBefore(corte, previsto);
        cerrar();
        this.refresh();
      } catch (e) {
        action.disabled = false;
        aviso.textContent = 'No se pudo archivar: ' + String(e);
      }
    });
  }

  private async renderFileTree(body: HTMLElement, actions: HTMLElement | null): Promise<void> {
    if (actions) {
      actions.innerHTML = `<button class="icon-btn" id="sb-refresh" title="Actualizar árbol">${icons.refresh(14)}</button>`;
      actions.querySelector('#sb-refresh')?.addEventListener('click', () => {
        this.expandedDirs.clear();
        this.refresh();
      });
    }
    body.innerHTML = '<div class="subtle" style="padding:8px">Leyendo directorio…</div>';
    try {
      const res = await this.core.listDir('');
      // El await puede resolverse con el usuario ya en otra pestaña: sin esta
      // guarda el árbol se estampa sobre la barra lateral de la vista nueva.
      if (!this.isShown('explorer') && !(body.id === 'right-explorer-body' && document.getElementById('panel-secondary')?.dataset.panel === 'explorer')) return;
      this.treeRoot = res.root;
      body.innerHTML = '';
      const rootLabel = document.createElement('div');
      rootLabel.className = 'section-label';
      rootLabel.style.padding = '2px 8px 6px';
      rootLabel.innerText = res.root.split(/[\\/]/).pop() || res.root;
      body.appendChild(rootLabel);
      this.appendEntries(body, res.entries, 0);
    } catch (e) {
      if (this.isShown('explorer') || body.id === 'right-explorer-body') {
        body.innerHTML = `<div class="empty-state" style="color:var(--danger)">${esc(String(e))}</div>`;
      }
    }
  }

  /** Inserta un nivel del árbol; las carpetas cargan sus hijos al desplegarse. */
  private appendEntries(host: HTMLElement, entries: FsEntry[], depth: number, after?: HTMLElement): void {
    const frag = document.createDocumentFragment();
    entries.forEach((entry) => {
      const row = document.createElement('div');
      row.className = 'list-item';
      row.style.paddingLeft = `${8 + depth * 12}px`;
      row.dataset.path = entry.path;
      row.dataset.dir = entry.isDir ? '1' : '0';
      row.dataset.depth = String(depth);
      // Icono por tipo, como en el auditor: la carpeta lleva su flecha de plegado y
      // el archivo, la forma de su familia. Antes todo archivo era el mismo
      // rectángulo gris y el árbol no se podía leer de un vistazo.
      const ico = entry.isDir ? folderIcon(false) : fileIcon(entry.name);
      setHtml(row, safeHtml`${entry.isDir
          ? safeHtml`<span class="list-item__icon list-item__caret">${raw(icons.chevronRight(11))}</span>`
          : ''}<span class="list-item__icon" style="color:${ico.color}">${raw(ico.svg)}</span><span class="list-item__label">${entry.name}</span>`);

      row.addEventListener('click', async (ev) => {
        ev.stopPropagation();
        if (entry.isDir) {
          await this.toggleDir(row, entry, depth);
        } else if (this.hooks.onOpenFile) {
          host.querySelectorAll('.list-item.is-active').forEach((n) => n.classList.remove('is-active'));
          row.classList.add('is-active');
          this.hooks.onOpenFile(entry.path, entry.name);
        }
      });

      // Clic derecho: crear archivo o carpeta sin pasar por el agente.
      //
      // Antes la única forma era pedírselo al agente o escribir un comando en
      // la terminal. Para un archivo vacío eso gasta una llamada al modelo y un
      // ciclo de aprobación entero para hacer lo que hace `touch`.
      row.addEventListener('contextmenu', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        // Sobre un archivo, el menú actúa sobre SU CARPETA: es lo que hace
        // cualquier explorador y evita tener que acertarle a la carpeta padre.
        const dir = entry.isDir ? entry.path : entry.path.replace(/[\\/][^\\/]*$/, '');
        this.showTreeMenu(ev as MouseEvent, dir, row, entry, depth);
      });
      frag.appendChild(row);
    });
    if (after && after.parentElement) after.parentElement.insertBefore(frag, after.nextSibling);
    else host.appendChild(frag);
  }

  /**
   * Menú contextual del árbol de archivos.
   *
   * Se construye en el momento y se destruye al elegir o al perder el foco: un
   * menú persistente escondido acaba desincronizado con el árbol que lo abrió.
   */
  private showTreeMenu(
    ev: MouseEvent,
    dir: string,
    row: HTMLElement,
    entry: FsEntry,
    depth: number
  ): void {
    document.getElementById('tree-context-menu')?.remove();

    const menu = document.createElement('div');
    menu.id = 'tree-context-menu';
    menu.style.cssText = [
      'position:fixed',
      `left:${ev.clientX}px`,
      `top:${ev.clientY}px`,
      'z-index:9600',
      'min-width:210px',
      'background:var(--bg-elevated, var(--bg-panel))',
      'border:1px solid var(--border)',
      'border-radius:8px',
      'padding:4px',
      'box-shadow:0 10px 30px rgba(0,0,0,.45)',
      'display:flex',
      'flex-direction:column',
      'gap:2px',
    ].join(';');

    const opciones: Array<{ etiqueta: string; accion: () => void }> = [
      {
        etiqueta: 'Nuevo archivo…',
        accion: () => void this.crearEnArbol(dir, 'file', '', row, entry, depth),
      },
      {
        etiqueta: 'Nueva carpeta…',
        accion: () => void this.crearEnArbol(dir, 'dir', '', row, entry, depth),
      },
      // Las plantillas evitan el paso de escribir la extensión, que es donde se
      // cometen las erratas. El contenido inicial es el mínimo que hace que el
      // archivo no esté vacío del todo y se reconozca el lenguaje.
      {
        etiqueta: 'Nuevo Python (.py)',
        accion: () =>
          void this.crearEnArbol(dir, 'file', '# \n', row, entry, depth, 'nuevo.py'),
      },
      {
        etiqueta: 'Nuevo Markdown (.md)',
        accion: () =>
          void this.crearEnArbol(dir, 'file', '# \n', row, entry, depth, 'nuevo.md'),
      },
      {
        etiqueta: 'Nuevo notebook (.ipynb)',
        accion: () =>
          void this.crearEnArbol(
            dir,
            'file',
            // Cuaderno vacío pero VÁLIDO: un .ipynb de 0 bytes no lo abre nada.
            JSON.stringify(
              { cells: [], metadata: {}, nbformat: 4, nbformat_minor: 5 },
              null,
              1
            ),
            row,
            entry,
            depth,
            'nuevo.ipynb'
          ),
      },
    ];

    for (const o of opciones) {
      const b = document.createElement('button');
      b.className = 'btn';
      b.textContent = o.etiqueta;
      b.style.cssText = 'justify-content:flex-start;width:100%;border:none;background:transparent';
      b.addEventListener('click', () => {
        menu.remove();
        o.accion();
      });
      menu.appendChild(b);
    }

    const pie = document.createElement('div');
    pie.className = 'subtle';
    pie.style.cssText = 'font-size:10px;padding:4px 8px 2px;opacity:.7';
    pie.textContent = dir;
    menu.appendChild(pie);

    document.body.appendChild(menu);

    // Reposicionar si se sale por abajo o por la derecha.
    const r = menu.getBoundingClientRect();
    if (r.bottom > window.innerHeight) menu.style.top = `${Math.max(4, ev.clientY - r.height)}px`;
    if (r.right > window.innerWidth) menu.style.left = `${Math.max(4, ev.clientX - r.width)}px`;

    const cerrar = (e: Event): void => {
      if (menu.contains(e.target as Node)) return;
      menu.remove();
      document.removeEventListener('mousedown', cerrar, true);
      document.removeEventListener('keydown', esc, true);
    };
    const esc = (e: KeyboardEvent): void => {
      if (e.key === 'Escape') cerrar(e);
    };
    // En el siguiente tick: si no, el propio clic derecho que abrió el menú lo
    // cerraría al instante.
    setTimeout(() => {
      document.addEventListener('mousedown', cerrar, true);
      document.addEventListener('keydown', esc, true);
    }, 0);
  }

  /** Pide el nombre y crea. Refresca la carpeta para que aparezca sin recargar. */
  private async crearEnArbol(
    dir: string,
    tipo: 'file' | 'dir',
    contenido: string,
    row: HTMLElement,
    entry: FsEntry,
    depth: number,
    sugerido = ''
  ): Promise<void> {
    const nombre = await promptModal({
      title: tipo === 'dir' ? 'Nueva carpeta' : 'Nuevo archivo',
      label: `Se creará dentro de ${dir}`,
      placeholder: tipo === 'dir' ? 'nombre-de-la-carpeta' : 'nombre.ext',
      initial: sugerido,
    });
    if (!nombre) return;

    try {
      const r =
        tipo === 'dir'
          ? await this.core.mkdir(dir, nombre)
          : await this.core.createFile(dir, nombre, contenido);

      // Refrescar la carpeta afectada. Si el clic fue sobre un archivo, la que
      // hay que repintar es la de su padre, no la fila pulsada.
      if (entry.isDir && this.expandedDirs.has(entry.path)) {
        await this.toggleDir(row, entry, depth); // cerrar
        await this.toggleDir(row, entry, depth); // y volver a abrir, ya con lo nuevo
      } else {
        // repinta la vista, que reconstruye el arbol (en B, la sección Archivos)
        if (this.isUnified()) this.openSection('explorer');
        else this.show(this.current);
      }

      notice(
        tipo === 'dir' ? `Carpeta creada:\n${r.path}` : `Archivo creado:\n${r.path}`,
        'ok'
      );
      // Un archivo recién creado se abre: es lo que se espera tras crearlo, y
      // ahorra tener que buscarlo en el árbol.
      if (tipo === 'file') this.hooks.onOpenFile?.(r.path, nombre);
    } catch (e) {
      notice(String(e), 'error');
    }
  }

  private async toggleDir(row: HTMLElement, entry: FsEntry, depth: number): Promise<void> {
    const isOpen = this.expandedDirs.has(entry.path);
    // La flecha y el icono de carpeta son nodos distintos desde que el arbol
    // usa iconos por tipo: hay que mover los dos o la carpeta se queda cerrada
    // con el contenido desplegado debajo.
    const caret = row.querySelector('.list-item__caret');
    const icon = row.querySelector('.list-item__icon:not(.list-item__caret)');

    if (isOpen) {
      this.expandedDirs.delete(entry.path);
      if (caret) caret.innerHTML = icons.chevronRight(11);
      if (icon) icon.innerHTML = folderIcon(false).svg;
      // Quita los descendientes: todos los hermanos siguientes con mayor profundidad.
      let next = row.nextElementSibling as HTMLElement | null;
      while (next && Number(next.dataset.depth ?? -1) > depth) {
        const toRemove = next;
        next = next.nextElementSibling as HTMLElement | null;
        toRemove.remove();
      }
      return;
    }

    this.expandedDirs.add(entry.path);
    if (caret) caret.innerHTML = icons.chevronDown(11);
    if (icon) icon.innerHTML = folderIcon(true).svg;
    try {
      const res = await this.core.listDir(entry.path);
      // Se insertan en orden inverso porque cada uno se coloca justo tras `row`.
      this.appendEntries(row.parentElement as HTMLElement, res.entries, depth + 1, row);
    } catch {
      this.expandedDirs.delete(entry.path);
      if (caret) caret.innerHTML = icons.chevronRight(11);
      if (icon) icon.innerHTML = folderIcon(false).svg;
    }
  }

  public showReplaceInFiles(): void {
    this.show('search');
    const controls = document.getElementById('search-replace-controls');
    if (controls) controls.style.display = '';
    document.getElementById('search-replacement')?.focus();
  }

  private renderSearch(body: HTMLElement): void {
    body.innerHTML = `
      <div class="col" style="gap:8px">
        <div class="switch-group" id="search-scope">
          <button class="switch-group__item is-active" data-scope="project" title="Buscar texto en los archivos del proyecto">Proyecto</button>
          <button class="switch-group__item" data-scope="web" title="Buscar en la web con el proveedor de búsqueda configurado">Web</button>
        </div>
        <input class="input" id="search-input" placeholder="Buscar en el proyecto…" />
        <button class="btn btn--sm" id="search-replace-toggle">Reemplazar en archivos</button>
        <div id="search-replace-controls" class="col" style="gap:6px;display:none">
          <input class="input" id="search-replacement" aria-label="Reemplazar por" placeholder="Reemplazar por (vacío para eliminar)…" />
          <div class="row" style="gap:6px;flex-wrap:wrap">
            <button class="btn btn--sm" id="search-replace-preview">Vista previa</button>
            <button class="btn btn--sm btn--primary" id="search-replace-apply" disabled>Aplicar reemplazos</button>
            <button class="btn btn--sm" id="search-replace-cancel">Cancelar</button>
          </div>
          <div id="search-replace-results" class="col" aria-live="polite" style="gap:6px;max-height:55vh;overflow:auto"></div>
        </div>
        <div class="row" style="gap:6px" id="search-opts">
          <label class="row subtle" style="gap:5px;font-size:11px"><input type="checkbox" id="search-case" /> Distinguir mayúsculas</label>
          <label class="row subtle" style="gap:5px;font-size:11px"><input type="checkbox" id="search-regex" /> Regex</label>
          <label class="row subtle" style="gap:5px;font-size:11px" title="Ranking BM25 del motor sobre los archivos rastreados por git (léxico, no semántico)"><input type="checkbox" id="search-ranking" /> Ranking</label>
          <label class="row subtle" style="gap:5px;font-size:11px" title="Búsqueda híbrida: fusión RRF del ranking BM25 con el coseno sobre el índice vectorial persistente del repo (o rerank del pool si no hay índice). Requiere la capa semántica configurada; si no, sale BM25 con la razón indicada"><input type="checkbox" id="search-semantic" /> Semántica</label>
          <button class="btn btn--ghost" id="search-embed-index" style="font-size:10px;padding:1px 8px" title="Construir o actualizar el índice vectorial persistente del repo con el proveedor de embeddings configurado (incremental — solo re-embebe lo que cambió)">Indexar</button>
        </div>
        <div id="search-embed-status" class="subtle" style="font-size:10px;padding:0 2px"></div>
        <div id="search-results" class="col" style="gap:2px"></div>
      </div>`;

    const input = body.querySelector<HTMLInputElement>('#search-input');
    const results = body.querySelector<HTMLElement>('#search-results');
    const opts = body.querySelector<HTMLElement>('#search-opts');
    const embedStatus = body.querySelector<HTMLElement>('#search-embed-status');
    const embedIndexBtn = body.querySelector<HTMLButtonElement>('#search-embed-index');
    this.bindReplaceInFiles(body);

    // E5.15: estado del índice vectorial persistente — visible sin suponerlo.
    // `repoEmbedStatus` informa la tabla real (empty/ready + cuentas), no un
    // estado inventado en la UI.
    const refreshEmbedStatus = async () => {
      if (!embedStatus) return;
      try {
        const root = this.treeRoot || (await this.core.listDir('')).root;
        const st = await this.core.repoEmbedStatus(root);
        embedStatus.textContent =
          st.state === 'ready'
            ? `índice vectorial: ${st.chunks_indexed} trozos · ${st.files_indexed} archivos · ${st.model}`
            : 'índice vectorial: vacío — usa «Indexar» con la capa semántica configurada';
      } catch {
        embedStatus.textContent = 'índice vectorial: no disponible';
      }
    };
    body.querySelector<HTMLInputElement>('#search-semantic')?.addEventListener('change', () => {
      void refreshEmbedStatus();
    });
    embedIndexBtn?.addEventListener('click', async () => {
      if (!embedStatus || !embedIndexBtn) return;
      embedIndexBtn.disabled = true;
      embedStatus.textContent = 'indexando vectores…';
      try {
        const root = this.treeRoot || (await this.core.listDir('')).root;
        const r = await this.core.repoEmbedIndex(root);
        embedStatus.textContent = r.indexed
          ? `índice listo: ${r.embedded} trozos embebidos · ${r.reused} reutilizados · ${r.removed} obsoletos · ${r.dim}d`
          : `índice no construido (${r.reason ?? r.error ?? 'desconocido'})`;
      } catch (err) {
        embedStatus.textContent = `índice: error — ${String(err)}`;
      } finally {
        embedIndexBtn.disabled = false;
      }
    });
    void refreshEmbedStatus();

    // La búsqueda web ya existía en el motor (`da_web_search`) y en el puente,
    // pero no tenía por dónde invocarse: `CoreApi.webSearch` no tenía un solo
    // llamador. Se cuelga aquí en vez de en el compositor porque comparte
    // exactamente la misma interacción que la búsqueda de proyecto.
    let scope: 'project' | 'web' = 'project';
    body.querySelectorAll<HTMLElement>('#search-scope [data-scope]').forEach((btn) => {
      btn.addEventListener('click', () => {
        scope = (btn.dataset.scope as 'project' | 'web') || 'project';
        body
          .querySelectorAll('#search-scope [data-scope]')
          .forEach((b) => b.classList.toggle('is-active', b === btn));
        if (input) {
          input.placeholder = scope === 'web' ? 'Buscar en la web…' : 'Buscar en el proyecto…';
          input.focus();
        }
        if (opts) opts.style.display = scope === 'web' ? 'none' : '';
        const replace = body.querySelector<HTMLElement>('#search-replace-controls');
        const replaceToggle = body.querySelector<HTMLElement>('#search-replace-toggle');
        if (replace) replace.style.display = 'none';
        if (replaceToggle) replaceToggle.style.display = scope === 'web' ? 'none' : '';
        if (results) results.innerHTML = '';
      });
    });

    input?.addEventListener('keydown', async (e) => {
      if (e.key !== 'Enter' || !input.value.trim() || !results) return;
      results.innerHTML = '<div class="subtle" style="padding:6px">Buscando…</div>';

      if (scope === 'web') {
        try {
          const raw = await this.core.webSearch(input.value.trim(), 8);
          const items = Array.isArray(raw)
            ? (raw as Array<Record<string, unknown>>)
            : ((raw as Record<string, unknown>)?.results as Array<Record<string, unknown>>) || [];
          if (!items.length) {
            results.innerHTML =
              '<div class="subtle" style="padding:6px">Sin resultados. Comprueba que hay una clave de proveedor de búsqueda en Configuración.</div>';
            return;
          }
          results.innerHTML = items
            .map((it) => {
              const title = String(it.title ?? it.name ?? it.url ?? '(sin título)');
              const url = String(it.url ?? it.link ?? '');
              const snippet = String(it.snippet ?? it.description ?? '');
              return `<div class="list-item" data-url="${escapeAttribute(url)}" title="${escapeAttribute(url)}">
                <div class="col" style="gap:2px">
                  <span class="list-item__label">${esc(title)}</span>
                  ${snippet ? `<span class="subtle" style="font-size:11px">${esc(snippet.slice(0, 160))}</span>` : ''}
                </div>
              </div>`;
            })
            .join('');
          results.querySelectorAll<HTMLElement>('[data-url]').forEach((el) => {
            el.addEventListener('click', () => {
              const u = el.dataset.url || '';
              if (u) this.hooks.onOpenExternal?.(u);
            });
          });
        } catch (err) {
          results.innerHTML = `<div style="color:var(--danger);padding:6px">${esc(String(err))}</div>`;
        }
        return;
      }

      try {
        const root = this.treeRoot || (await this.core.listDir('')).root;
        if (
          body.querySelector<HTMLInputElement>('#search-ranking')?.checked ||
          body.querySelector<HTMLInputElement>('#search-semantic')?.checked
        ) {
          // E5.14/E5.15: ranking del motor. "Semántica" pide el rerank por
          // embeddings; el JSON declara query_mode y semantic_status con la
          // razón honesta si la capa no está configurada.
          const semantic = !!body.querySelector<HTMLInputElement>('#search-semantic')?.checked;
          const r = await this.core.repoSearch(input.value.trim(), root, 50, semantic ? 'hybrid' : 'ranking');
          if (!r.matches.length) {
            results.innerHTML = '<div class="subtle" style="padding:6px">Sin resultados.</div>';
            return;
          }
          const semNote =
            r.semantic_status && r.semantic_status !== 'ok'
              ? ` · sin rerank (${r.semantic_status})`
              : '';
          // E5.15: el estado del índice vectorial viaja en la respuesta — la
          // cabina lo muestra tal cual, no lo deduce de los resultados.
          const idxNote = r.index
            ? ` · índice ${r.index.state === 'ready' ? `${r.index.chunks_indexed}t/${r.index.files_indexed}f` : r.index.state}`
            : '';
          results.innerHTML =
            `<div class="subtle" style="padding:2px 6px;font-size:10px">${esc(r.query_mode.toUpperCase())} · ${esc(r.files_scanned)} archivos · ${esc(r.elapsed_ms)} ms${r.truncated ? ' · índice parcial' : ''}${esc(idxNote)}${esc(semNote)}</div>` +
            r.matches
              .map(
                (m) =>
                  `<div class="list-item" data-path="${escapeAttribute(m.path)}" title="${escapeAttribute(m.snippet)}">
                    <div class="col" style="gap:1px">
                      <span class="list-item__label">${esc(m.path.split(/[\\/]/).pop() || '')}<span class="subtle">:${esc(m.line)} · ${esc(m.score.toFixed(2))}${m.source && m.source !== 'bm25' ? ` · ${esc(m.source)}` : ''}</span></span>
                      ${m.snippet ? `<span class="subtle" style="font-size:10px">${esc(m.snippet.slice(0, 120))}</span>` : ''}
                    </div>
                  </div>`
              )
              .join('');
          void refreshEmbedStatus();
          results.querySelectorAll<HTMLElement>('[data-path]').forEach((el) => {
            el.addEventListener('click', () => {
              const p = el.dataset.path || '';
              this.hooks.onOpenFile?.(p, p.split(/[\\/]/).pop() || p);
            });
          });
          return;
        }
        const matches = await this.core.search(input.value.trim(), root, {
          caseSensitive: !!body.querySelector<HTMLInputElement>('#search-case')?.checked,
          isRegex: !!body.querySelector<HTMLInputElement>('#search-regex')?.checked,
        });
        if (!matches.length) {
          results.innerHTML = '<div class="subtle" style="padding:6px">Sin resultados.</div>';
          return;
        }
        results.innerHTML = matches
          .slice(0, 200)
          .map(
            (m) =>
              `<div class="list-item" data-path="${escapeAttribute(m.filePath)}">
                <span class="list-item__label">${esc(m.filePath.split(/[\\/]/).pop() || '')}<span class="subtle">:${m.lineNumber}</span></span>
              </div>`
          )
          .join('');
        results.querySelectorAll<HTMLElement>('[data-path]').forEach((el) => {
          el.addEventListener('click', () => {
            const p = el.dataset.path || '';
            this.hooks.onOpenFile?.(p, p.split(/[\\/]/).pop() || p);
          });
        });
      } catch (err) {
        results.innerHTML = `<div style="color:var(--danger);padding:6px">${esc(String(err))}</div>`;
      }
    });
  }

  /** La vista previa es de solo lectura; Cancelar nunca inicia doc.save. */
  private bindReplaceInFiles(body: HTMLElement): void {
    const input = body.querySelector<HTMLInputElement>('#search-input')!;
    const replacement = body.querySelector<HTMLInputElement>('#search-replacement')!;
    const controls = body.querySelector<HTMLElement>('#search-replace-controls')!;
    const results = body.querySelector<HTMLElement>('#search-replace-results')!;
    const preview = body.querySelector<HTMLButtonElement>('#search-replace-preview')!;
    const apply = body.querySelector<HTMLButtonElement>('#search-replace-apply')!;
    const cancel = body.querySelector<HTMLButtonElement>('#search-replace-cancel')!;
    type Change = { path: string; before: string; after: string; count: number };
    let plan: { root: string; changes: Change[] } | null = null;
    let generation = 0;
    let applying = false;
    let confirming = false;
    const canonical = (path: string) => path.replace(/\//g, '\\').replace(/\\+$/, '').toLowerCase();
    const inRoot = (file: string, root: string) => {
      const parts = file.replace(/\//g, '\\').split('\\');
      return !parts.some(p => p === '.' || p === '..') && canonical(file).startsWith(canonical(root) + '\\');
    };
    const invalidate = () => {
      if (applying) return;
      generation++; plan = null; apply.disabled = true; results.innerHTML = '';
    };
    input.addEventListener('input', invalidate);
    replacement.addEventListener('input', invalidate);
    body.querySelectorAll<HTMLInputElement>('#search-opts input').forEach(el => el.addEventListener('change', invalidate));
    body.querySelectorAll<HTMLElement>('#search-scope [data-scope]').forEach(el => el.addEventListener('click', invalidate));
    body.querySelector('#search-replace-toggle')?.addEventListener('click', () => {
      controls.style.display = ''; replacement.focus();
    });
    cancel.addEventListener('click', invalidate);
    preview.addEventListener('click', async () => {
      if (applying) return;
      invalidate();
      const ticket = generation;
      const alive = () => ticket === generation && controls.isConnected && this.isShown('search');
      const query = input.value;
      if (!query) { results.textContent = 'Introduce el texto que quieres reemplazar.'; return; }
      if (body.querySelector<HTMLInputElement>('#search-ranking')?.checked || body.querySelector<HTMLInputElement>('#search-semantic')?.checked) {
        results.textContent = 'Desactiva Ranking y Semántica para reemplazar coincidencias de texto.';
        return;
      }
      const options = { caseSensitive: !!body.querySelector<HTMLInputElement>('#search-case')?.checked,
        isRegex: !!body.querySelector<HTMLInputElement>('#search-regex')?.checked };
      const newText = replacement.value;
      results.textContent = 'Preparando vista previa…';
      try {
        const pattern = new RegExp(options.isRegex ? query : query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), options.caseSensitive ? 'g' : 'gi');
        // Consultar la raíz actual, no el treeRoot que pudo quedar en caché.
        const root = (await this.core.listDir('')).root;
        if (!root) throw new Error('No hay una raíz activa.');
        const matches = await this.core.search(query, root, options);
        if (matches.length >= 5000) throw new Error('La búsqueda alcanzó el límite de 5000 líneas. Acota la consulta antes de reemplazar.');
        const changes: Change[] = [];
        const rows: string[] = [];
        for (const path of new Set(matches.map(match => match.filePath))) {
          if (!alive()) return;
          if (!inRoot(path, root)) throw new Error('La búsqueda devolvió una ruta fuera de la raíz activa.');
          if (this.hooks.hasUnsavedChanges?.(path)) {
            rows.push(`<div>${esc(path)}: cambios sin guardar; se conserva el borrador.</div>`); continue;
          }
          const doc = await this.core.openDoc(path);
          if (doc.readOnly) { rows.push(`<div>${esc(path)}: solo lectura; no se reemplazará.</div>`); continue; }
          if (pareceBinario(doc.content)) { rows.push(`<div>${esc(path)}: binario; no se reemplazará.</div>`); continue; }
          let count = 0;
          const after = doc.content.replace(pattern, () => { count++; return newText; });
          if (!count || after === doc.content) continue;
          changes.push({ path, before: doc.content, after, count });
          rows.push(`<div class="section-label">${esc(path)} · ${count} coincidencias</div>${previewHtml(doc.content, after)}`);
        }
        if (!alive()) return;
        plan = { root, changes };
        results.innerHTML = `<div>Raíz: ${esc(root)} · ${changes.length} archivos con cambios. Vista previa; todavía no se ha escrito.</div>` + rows.join('');
        apply.disabled = !changes.length;
      } catch (error) {
        if (alive()) results.textContent = String(error);
      }
    });
    apply.addEventListener('click', async () => {
      if (!plan || applying || confirming) return;
      const selected = plan;
      const ticket = generation;
      apply.disabled = true;
      confirming = true;
      const approved = await confirmModal({ title: 'Reemplazar en archivos',
        paragraphs: [`${selected.changes.length} archivos bajo ${selected.root}. Se aplicará la vista previa mostrada.`,
          'Cancelar conserva todos los archivos. Una vez iniciada la escritura, espera a que termine.'],
        confirmLabel: 'Aplicar reemplazos', cancelLabel: 'Cancelar' });
      confirming = false;
      if (!approved) { if (plan === selected) apply.disabled = false; return; }
      if (ticket !== generation || !controls.isConnected || !this.isShown('search')) return;
      const saved: string[] = [];
      try {
        if (canonical((await this.core.listDir('')).root) !== canonical(selected.root)) throw new Error('La raíz activa cambió. Genera otra vista previa.');
        // Validar el lote completo antes de la primera escritura.
        for (const change of selected.changes) {
          const current = await this.core.openDoc(change.path);
          if (current.readOnly || current.content !== change.before || this.hooks.hasUnsavedChanges?.(change.path)) {
            throw new Error(`${change.path} cambió o es de solo lectura. Genera otra vista previa.`);
          }
        }
        if (ticket !== generation || !controls.isConnected || !this.isShown('search')) return;
        if (canonical((await this.core.listDir('')).root) !== canonical(selected.root)) throw new Error('La raíz activa cambió. Genera otra vista previa.');
        if (ticket !== generation || !controls.isConnected || !this.isShown('search') || applying || plan !== selected) return;
        applying = true; plan = null;
        preview.disabled = cancel.disabled = input.disabled = replacement.disabled = true;
        for (const change of selected.changes) {
          if (this.hooks.hasUnsavedChanges?.(change.path)) throw new Error(`${change.path}: hay cambios sin guardar.`);
          // Exactamente el guardado del editor: el host conserva confinamiento,
          // escritura atómica por archivo y detección de conflictos de disco.
          await this.core.saveDoc(change.path, change.after, false);
          saved.push(change.path);
        }
        results.textContent = `${saved.length} archivos reemplazados.`;
        notice(`${saved.length} archivos reemplazados.`, 'ok');
      } catch (error) {
        results.textContent = `${saved.length} archivos guardados. ${String(error)}`;
        notice(results.textContent, 'error');
      } finally {
        applying = false; plan = null; apply.disabled = true;
        preview.disabled = cancel.disabled = input.disabled = replacement.disabled = false;
        if (saved.length) await this.hooks.onFilesReplaced?.(saved);
      }
    });
  }

  /** Resumen numérico del Monitor; el detalle vive en el panel central. */
  private async renderMonitorNav(body: HTMLElement, actions: HTMLElement | null): Promise<void> {
    if (actions) {
      actions.innerHTML = `<button class="icon-btn" id="sb-refresh" title="Actualizar">${icons.refresh(14)}</button>`;
      actions.querySelector('#sb-refresh')?.addEventListener('click', () => this.refresh());
    }
    body.innerHTML = '<div class="subtle" style="padding:8px">Consultando el motor…</div>';
    try {
      const [st, info, sessions, approvals] = await Promise.all([
        this.core.status(),
        this.core.catalogInfo().catch(() => null),
        this.core.listSessions().catch(() => []),
        this.core.pendingApprovals().catch(() => []),
      ]);
      if (!this.isShown('monitor')) return;
      const rows: Array<[string, string]> = [
        ['Motor', st.engineReady ? 'listo' : 'no inicializado'],
        ['Versión', formatEngineVersion(st.version)],
        ['Proveedores', String(st.providerCount)],
        ['Claves API', String(st.keyCount)],
        ['Modelos', info ? String(info.model_count) : '—'],
        ['Sesiones', String(sessions.length)],
        ['Aprobaciones', String(approvals.length)],
      ];
      body.innerHTML = rows
        .map(
          ([k, v]) =>
            `<div class="list-item" style="cursor:default"><span class="list-item__label">${esc(k)}</span><span class="list-item__meta">${esc(v)}</span></div>`
        )
        .join('');
    } catch (e) {
      if (this.isShown('monitor')) {
        body.innerHTML = `<div class="empty-state" style="color:var(--danger)">${esc(String(e))}</div>`;
      }
    }
  }

  /**
   * Vista de Spaces.
   *
   * Antes pintaba MONTAJES: leía `core.mounts.list` y listaba carpetas
   * enlazadas bajo el rótulo "Spaces". No era un atajo, era lo único que había
   * — `SpacesPanel` existía y nadie lo importaba, y el motor no tenía export
   * con el que alcanzar `spaces.zig`. Ahora la vista es el panel de verdad.
   *
   * Se construye en cada visita porque el cuerpo se vacía al cambiar de vista;
   * el constructor ya consulta al motor, así que la lista siempre llega al día.
   */
  private async renderSpaces(body: HTMLElement): Promise<void> {
    // 9-nov: la gestión de Spaces está en la vista central (catalog_sessions,
    // montada desde main.ts); aquí solo se explica, sin duplicar el panel.
    this.spacesPanel = null;
    body.innerHTML = '<div class="subtle" style="padding:8px 12px;font-size:12px;line-height:1.5">Cada orden en un repositorio git crea su propio space. Para crear uno a mano, archivar o podar, usa la vista central.</div>';
  }

  private async renderMcp(body: HTMLElement): Promise<void> {
    body.innerHTML = '<div class="subtle" style="padding:8px">Consultando cliente MCP…</div>';
    try {
      const st = await this.core.mcpStatus();
      const tools = st.connected ? ((await this.core.mcpTools()) as Array<Record<string, unknown>>) : [];
      // Igual que en el resto de renders async: si el usuario ya cambió de
      // pestaña, este contenido pertenece a una vista que ya no está activa.
      if (!this.isShown('mcp')) return;
      body.innerHTML = `
        <div class="col" style="gap:8px">
          <span class="pill ${st.connected ? 'pill--online' : 'pill--offline'}">
            <span class="pill__dot"></span>${st.connected ? 'Servidor MCP conectado' : 'Sin servidor MCP'}
          </span>
          <div class="section-label" style="padding:4px 2px">Herramientas expuestas (${tools.length})</div>
          ${
            tools.length
              ? tools
                  .map(
                    (t) =>
                      safeHtml`<div class="list-item"><span class="list-item__icon">${raw(icons.plug(13))}</span><span class="list-item__label truncate">${String(t.name ?? '')}</span></div>`.value
                  )
                  .join('')
              : '<div class="subtle" style="padding:4px 2px">Conecta un servidor desde el panel central.</div>'
          }
        </div>`;
    } catch (e) {
      if (this.isShown('mcp')) {
        body.innerHTML = `<div class="empty-state" style="color:var(--danger)">${esc(String(e))}</div>`;
      }
    }
  }

  private renderSettingsNav(body: HTMLElement): void {
    const active = document.querySelector<HTMLElement>('#settings-tabs [aria-current="page"]')?.dataset.section || 'providers';
    // (e): mismos grupos que el índice de la página 5 (General, Modelos…).
    let lastGroup = '';
    setHtml(body, joinHtml(SETTINGS_SECTIONS
      .map((s) => {
        const head = s.group && s.group !== lastGroup
          ? safeHtml`<div class="section-label settings-side-group">${s.group}</div>`
          : safeHtml``;
        lastGroup = s.group ?? lastGroup;
        return safeHtml`${head}<button type="button" class="list-item ${s.id === active ? 'is-active' : ''}" data-settings-section="${s.id}" aria-current="${s.id === active ? 'page' : 'false'}"><span class="list-item__label">${s.label}</span></button>`;
      })));
    body.querySelectorAll<HTMLElement>('[data-settings-section]').forEach((el) => {
      el.addEventListener('click', () => {
        body.querySelectorAll('.list-item').forEach((n) => n.classList.remove('is-active'));
        el.classList.add('is-active');
        document.dispatchEvent(
          new CustomEvent('devagents:settings-section', { detail: el.dataset.settingsSection })
        );
      });
    });
  }
}

// --- Utilidades --------------------------------------------------------------



function line(label: string, value: string): string {
  return safeHtml`<div class="row" style="gap:10px;padding:2px 0"><span class="subtle" style="min-width:180px">${label}</span><span>${value}</span></div>`.value;
}


