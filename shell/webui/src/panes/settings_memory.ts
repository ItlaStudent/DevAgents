import { splashEnabled, setSplashEnabled } from '../design/boot_splash';
import { escapeText as esc, escapeAttribute } from '../design/html';
import {
  CoreApi,
  ProviderInfo,
  ProviderModel,
  ModelSelection,
  ExternalAgent,
  KeyInfo,
  GovernanceMode,
  EngineStatusPayload,
  PluginItem,
  BudgetState,
  UsageWeek,
  ProjectRules,
  CliAccountsState,
} from '../bridge/core_api';
import { icons } from '../design/icons';
import { updatePermissionBadge, formatEngineVersion } from '../layout/layout';
import { bindableCommands, comboFromEvent, effectiveShortcut, isAssignable, isCustomized, resetShortcut, setShortcut } from '../app/keybindings';
import { getLang, setLang } from '../i18n/i18n';
import { UpdateController, sharedUpdateController } from '../components/update_view';
import { raiseAlert, clearAlert } from '../design/alerts';

/**
 * Panel de Configuración.
 *
 * Es el punto donde el usuario conecta la API de Claude (Anthropic) y una o
 * varias claves de Gemini/Google (multi-cuenta), gestiona el catálogo de
 * modelos, el modo de gobernanza, el tema visual y consulta el estado del
 * motor. Todo lo que se ve viene de `CoreApi`; nada aquí es simulado.
 */

export type SettingsSection =
  | 'providers'
  | 'models'
  | 'governance'
  | 'permissions'
  | 'hooks'
  | 'remote'
  | 'plugins'
  | 'skills'
  | 'memory'
  | 'appearance'
  | 'agents'
  | 'rules'
  | 'accounts'
  | 'about';

/** @deprecated Se mantiene solo por compatibilidad con arneses de prueba antiguos. */
export interface SpecialistEntry {
  name: string;
  department: string;
  assignedModel: string;
}

/**
 * USUARIO-NUEVO A5 (10-nov): la pasarela HTTP de OpenCode Zen rechaza sus
 * modelos gratuitos (403 FreeTierError); solo funcionan desde su CLI.
 */
const OPENCODE_FREE_NOTE =
  'Los modelos gratuitos de OpenCode solo funcionan desde su CLI: están en Agentes › OpenCode. Con esta clave, por HTTP, solo se usan sus modelos de pago.';

/** Fila de agente externo tal como la usa Configuración (subconjunto de ExternalAgent). */
interface ExternalAgentRow {
  provider: string;
  cli: string;
  display: string;
  version: string | null;
  session: string;
  session_reason?: string | null;
  authenticode?: string;
  exe?: string;
  label?: string;
  ignored_env?: string | null;
  enumeration_status?: string;
  enumeration_reason?: string | null;
  rejected?: Array<{ path: string; version: string | null; reason: string }>;
  /** B1: escritores huérfanos aceptados en la instalación en uso. */
  acl_orphan_note?: string | null;
  /** una app empaquetada (una sola) que puede modificar la instalación. */
  acl_appcontainer_writers?: Array<{ sid: string; app: string | null }>;
  models: Array<{ slug: string; reasoning_efforts?: string[]; reasoning_effort?: string; origin?: string }>;
}

interface ThemeManagerLike {
  getAvailableThemes(): { id: string; name: string }[];
  applyTheme(id: string): void;
  getCurrentThemeId(): string;
}

interface FormMsg {
  type: 'ok' | 'error';
  text: string;
}

interface ConnectOffer {
  kind: 'claude' | 'gemini';
  name: string;
  apiStyle: string;
  baseUrl: string;
}

/**
 * (e): secciones, nombres y grupos de la página 5 de la maqueta
 * aprobada (Configuración con índice agrupado a la izquierda, como Claude o
 * VS Code). «Agentes externos» es nueva: reúne lo que vivía repartido entre el
 * selector de modelos y la barra de estado.
 */
export const SETTINGS_SECTIONS: ReadonlyArray<{ id: SettingsSection; label: string; group: string }> = [
  { id: 'appearance', label: 'Apariencia', group: 'General' },
  { id: 'providers', label: 'Proveedores', group: 'Modelos' },
  { id: 'models', label: 'Modelos', group: 'Modelos' },
  { id: 'governance', label: 'Gobernanza y presupuesto', group: 'Modelos' },
  { id: 'agents', label: 'Agentes externos', group: 'Agentes' },
  { id: 'rules', label: 'Reglas del proyecto', group: 'Agentes' },
  { id: 'accounts', label: 'Cuentas de CLI', group: 'Agentes' },
  { id: 'permissions', label: 'Permisos', group: 'Seguridad' },
  { id: 'hooks', label: 'Hooks', group: 'Seguridad' },
  { id: 'skills', label: 'Skills', group: 'Extensiones' },
  { id: 'plugins', label: 'Plugins', group: 'Extensiones' },
  { id: 'memory', label: 'Memoria', group: 'Memoria y avisos' },
  { id: 'remote', label: 'Avisos y acceso remoto', group: 'Memoria y avisos' },
  { id: 'about', label: 'Acerca de y ayuda', group: 'Sistema' },
];

const SECTION_DESCRIPTIONS: Record<SettingsSection, string> = {
  providers: 'Conecta tus proveedores y administra las cuentas que usa el motor.',
  models: 'Consulta el catálogo, tus favoritos y el modelo de planificación.',
  governance: 'Elige cómo se asignan los modelos y controla las llamadas de pago.',
  permissions: 'Define qué acciones requieren tu aprobación y qué comandos se bloquean.',
  hooks: 'Prepara las comprobaciones que se ejecutan antes y después de cada acción.',
  remote: 'Recibe avisos y controla el acceso a tus órdenes desde un túnel de confianza.',
  skills: 'Enlaza carpetas para incorporar capacidades al agente.',
  plugins: 'Administra las extensiones nativas y su confianza explícita.',
  memory: 'Consulta el contexto y las lecciones que conserva el agente.',
  appearance: 'Disposición, tema y ventana. Los cambios se aplican al instante.',
  agents: 'Claude Code, Codex, Gemini CLI y OpenCode, cada uno con sus propias directrices.',
  accounts: 'Varias cuentas de Codex o Claude Code, cada una en su carpeta; si una agota su cuota, la orden sigue con la siguiente.',
  rules: 'Las reglas de programación o de seguridad que siguen todos los modos y agentes en este proyecto.',
  about: 'Versión y estado del motor, y la ayuda: preguntas frecuentes, diagnóstico y tutorial.',
};



function errText(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

type PermissionMode = 'normal' | 'accept_edits' | 'bypass' | 'autonomous';

interface PermissionsState {
  mode: PermissionMode;
  allow: string[];
  deny: string[];
}

const PERMISSIONS_STORAGE_KEY = 'devagents.permissions';

function defaultPermissions(): PermissionsState {
  return { mode: 'normal', allow: [], deny: [] };
}

/**
 * Permisos: manda el motor, que guarda la configuración entre arranques y la
 * expone con `core.permissions.get`. El espejo de localStorage (clave
 * `devagents.permissions`) solo sirve para pintar el indicador antes de que
 * responda el motor; nunca se reaplica al abrir la sección ni al arrancar
 * (eso abriría el diálogo del host sin que la persona haya tocado nada).
 */
const HOOKS_STORAGE_KEY = 'devagents.hooks';

interface HooksState {
  enabled: boolean;
  preEdit: string;
  postEdit: string;
  preCommand: string;
  postCommand: string;
}

/** Mismo patrón que los permisos: el motor no tiene getter, así que hay espejo. */
function loadHooksFromStorage(): HooksState {
  const empty: HooksState = {
    enabled: false,
    preEdit: '',
    postEdit: '',
    preCommand: '',
    postCommand: '',
  };
  try {
    const raw = window.localStorage.getItem(HOOKS_STORAGE_KEY);
    if (!raw) return empty;
    const p = JSON.parse(raw);
    return {
      enabled: !!p?.enabled,
      preEdit: typeof p?.preEdit === 'string' ? p.preEdit : '',
      postEdit: typeof p?.postEdit === 'string' ? p.postEdit : '',
      preCommand: typeof p?.preCommand === 'string' ? p.preCommand : '',
      postCommand: typeof p?.postCommand === 'string' ? p.postCommand : '',
    };
  } catch {
    return empty;
  }
}

function loadPermissionsFromStorage(): PermissionsState {
  try {
    const raw = window.localStorage.getItem(PERMISSIONS_STORAGE_KEY);
    if (!raw) return defaultPermissions();
    const parsed = JSON.parse(raw);
    const modes: PermissionMode[] = ['normal', 'accept_edits', 'bypass', 'autonomous'];
    const mode: PermissionMode = modes.includes(parsed?.mode) ? parsed.mode : 'normal';
    const allow = Array.isArray(parsed?.allow) ? parsed.allow.filter((v: unknown) => typeof v === 'string') : [];
    const deny = Array.isArray(parsed?.deny) ? parsed.deny.filter((v: unknown) => typeof v === 'string') : [];
    return { mode, allow, deny };
  } catch {
    return defaultPermissions();
  }
}

function savePermissionsToStorage(state: PermissionsState): void {
  try {
    window.localStorage.setItem(PERMISSIONS_STORAGE_KEY, JSON.stringify(state));
  } catch {
    // localStorage puede fallar (modo privado, cuota agotada); no bloquea la sesión actual.
  }
}

/** Contexto del modelo con separador de miles, p. ej. 1000000 -> "1.000.000". */
function formatThousands(n: number): string {
  return n.toLocaleString('es-ES');
}

/** Sugiere la siguiente etiqueta libre para una clave nueva del mismo proveedor (multi-cuenta). */
function suggestLabel(provider: string, keys: KeyInfo[]): string {
  const sanitizedProvider = (provider || 'KEY')
    .toUpperCase()
    .replace(/[^A-Z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '') || 'KEY';

  const existing = keys.filter((k) => k.provider === provider).map((k) => k.label || '');
  if (!existing.length) return `${sanitizedProvider}_01`;

  const re = /^(.*)_(\d+)$/;
  let base = sanitizedProvider;
  let maxN = 0;
  let width = 2;
  existing.forEach((label) => {
    const m = re.exec(label);
    if (!m) return;
    const n = parseInt(m[2], 10);
    if (Number.isNaN(n)) return;
    if (n >= maxN) {
      maxN = n;
      base = m[1];
    }
    width = Math.max(width, m[2].length);
  });
  return `${base}_${String(maxN + 1).padStart(width, '0')}`;
}

export class UnifiedSettingsPanel {
  private container: HTMLElement;
  private core?: CoreApi;
  private section: SettingsSection = 'providers';

  // --- Proveedores y claves -------------------------------------------------
  private providers: ProviderInfo[] = [];
  private keys: KeyInfo[] = [];
  private providersLoaded = false;
  private providersError: string | null = null;
  private keyFormMsg: FormMsg | null = null;
  private addProviderOpen = false;
  private addProviderMsg: FormMsg | null = null;
  private connectOffer: ConnectOffer | null = null;
  private preselectProvider = '';

  // --- Modelos ---------------------------------------------------------------
  private modelsLoaded = false;
  /** El autodescubrimiento se intenta una vez por sesión, nunca en bucle. */
  private autoDiscoverTried = false;
  private modelsError: string | null = null;
  private modelsFilter = '';
  private catalog: { catalog_path_abs: string; model_count: number; provider_count: number; key_count: number } | null =
    null;
  private planModel: { provider: string; model: string } = { provider: '', model: '' };
  private modelsMsg: FormMsg | null = null;
  private selectionRows: ModelSelection[] = [];
  private externalModels: ExternalAgent[] = [];

  // --- Gobernanza --------------------------------------------------------------
  private governanceLoaded = false;
  private governanceError: string | null = null;
  private governanceMode: GovernanceMode | null = null;
  /** E1.18/F4: presupuesto de pago (se carga con la sección de gobernanza). */
  private budget: BudgetState | null = null;
  private budgetMsg: FormMsg | null = null;
  private budgetError: string | null = null;
  /** E1.16/F4: medidor del plan en la ventana movil de 7 dias. */
  private usageWeek: UsageWeek | null = null;
  private usageWeekError: string | null = null;

  // --- Permisos --------------------------------------------------------------
  private permissionsLoaded = false;
  private permissionsError: string | null = null;
  /** Resultado de «Volver a pedir confirmación para Auto y Omitir». */
  private permissionsNote: string | null = null;
  private permissions: PermissionsState = defaultPermissions();
  /** Bypass pulsado pero aún sin confirmar; ver permissionsMarkup(). */

  // --- Acerca de -----------------------------------------------------------------
  private aboutLoaded = false;
  private aboutError: string | null = null;
  private aboutStatus: EngineStatusPayload | null = null;
  private aboutCatalogPath = '';

  constructor(container: HTMLElement, core?: CoreApi) {
    this.container = container;
    this.core = core;
    void this.refresh();
  }

  /** Cambia de sección; usa la caché si ya se cargó, sin bloquear la UI. */
  public showSection(section: string): void {
    const match = SETTINGS_SECTIONS.find((s) => s.id === section);
    this.section = match ? match.id : 'providers';
    document.querySelectorAll<HTMLElement>('#sidebar-body [data-settings-section]').forEach((entry) => {
      const selected = entry.dataset.settingsSection === this.section;
      entry.classList.toggle('is-active', selected);
      if (selected) entry.setAttribute('aria-current', 'page');
      else entry.removeAttribute('aria-current');
    });
    this.renderShell();
    void this.loadAndRenderSection();
  }

  /** Fuerza una recarga completa desde el motor y repinta la sección activa. */
  public async refresh(): Promise<void> {
    this.providersLoaded = false;
    this.modelsLoaded = false;
    this.governanceLoaded = false;
    this.permissionsLoaded = false;
    this.aboutLoaded = false;
    this.renderShell();
    await this.loadAndRenderSection();
  }

  /** @deprecated sin efecto: el catálogo de especialistas vive ahora en Proveedores/Modelos. */
  public setSpecialists(_specialists: SpecialistEntry[]): void {
    // no-op: mantenido por compatibilidad con arneses de prueba antiguos.
  }

  // ---------------------------------------------------------------- Esqueleto

  private renderShell(): void {
    if (!this.core) {
      this.container.innerHTML = `
        <div class="empty-state" style="height:100%">
          <span style="color:var(--danger)">${icons.alert(28)}</span>
          <span class="empty-state__title">Configuración no disponible</span>
          <span>El panel no recibió acceso al motor (CoreApi). Reinicia la cabina o revisa la inicialización.</span>
        </div>`;
      return;
    }

    // (e): página 5 de la maqueta. Índice agrupado a la izquierda
    // (sigue siendo #settings-tabs con sus [data-section]), buscador de
    // ajustes y la sección a la derecha.
    const groups: string[] = [];
    for (const sec of SETTINGS_SECTIONS) if (!groups.includes(sec.group)) groups.push(sec.group);
    const searchFocused = typeof document !== 'undefined' && document.activeElement?.id === 'settings-search';
    this.container.innerHTML = `
      <div class="col settings-workspace" style="height:100%">
        <div class="row settings-toolbar">
          <span class="row" style="gap:8px">
            <span style="color:var(--accent);display:inline-flex">${icons.settings(16)}</span>
            <span style="font-weight:600">Configuración</span>
          </span>
          <span class="row settings-toolbar__actions">
            <label class="settings-search">${icons.search(13)}<input type="search" id="settings-search" placeholder="Buscar ajuste…" aria-label="Buscar ajuste" value="${escapeAttribute(this.settingsQuery ?? '')}" autocomplete="off" /></label>
            <button class="btn" id="btn-settings-refresh" title="Actualizar todas las secciones" aria-label="Actualizar configuración">${icons.refresh(14)}<span>Actualizar</span></button>
            <button class="icon-btn settings-close" id="btn-settings-close" title="Cerrar Configuración y volver (Esc)" aria-label="Cerrar Configuración">${icons.close(15)}</button>
          </span>
        </div>
        <div class="settings-split">
          <nav class="settings-navigation" id="settings-tabs" aria-label="Secciones de Configuración">
            ${groups.map((g) => `<div class="settings-nav__group" data-group="${escapeAttribute(g)}">${esc(g)}</div>` + SETTINGS_SECTIONS.filter((x) => x.group === g).map(
              (x) => `<button class="panel-tab settings-nav__item ${x.id === this.section ? 'is-active' : ''}" data-section="${x.id}" data-group="${escapeAttribute(g)}" ${x.id === this.section ? 'aria-current="page"' : ''} aria-controls="settings-body" title="Abrir la sección ${escapeAttribute(x.label)}">${esc(x.label)}</button>`
            ).join('')).join('')}
            <div class="settings-nav__empty subtle" id="settings-search-empty" hidden>Ningún ajuste coincide.</div>
          </nav>
          <div class="scroll-y grow settings-body" id="settings-body" role="region" aria-labelledby="settings-section-title"></div>
        </div>
      </div>`;

    this.container.querySelectorAll<HTMLElement>('#settings-tabs [data-section]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const section = btn.dataset.section || 'providers';
        this.showSection(section);
      });
    });
    const search = this.container.querySelector<HTMLInputElement>('#settings-search');
    if (search) {
      search.addEventListener('input', () => {
        this.settingsQuery = search.value;
        this.filterSettingsNav();
      });
      search.addEventListener('keydown', (event) => {
        if (event.key !== 'Enter') return;
        const first = [...this.container.querySelectorAll<HTMLElement>('#settings-tabs [data-section]')].find((b) => !b.hidden);
        if (first) {
          event.preventDefault();
          this.showSection(first.dataset.section || 'providers');
        }
      });
      this.filterSettingsNav();
      if (searchFocused) {
        search.focus();
        search.setSelectionRange(search.value.length, search.value.length);
      }
    }

    this.container.querySelector('#btn-settings-refresh')?.addEventListener('click', () => {
      void this.refresh();
    });
  }

  /** Texto del buscador de ajustes (se conserva al cambiar de sección). */
  private settingsQuery = '';

  /** Filtra el índice por nombre, grupo y descripción de cada sección (sin tildes). */
  private filterSettingsNav(): void {
    const fold = (t: string): string => t.normalize('NFD').replace(/[\u0300-\u036f]/g, '').toLowerCase();
    const q = fold((this.settingsQuery ?? '').trim());
    let visible = 0;
    const groupsWithHits = new Set<string>();
    this.container.querySelectorAll<HTMLElement>('#settings-tabs [data-section]').forEach((btn) => {
      const sec = SETTINGS_SECTIONS.find((x) => x.id === btn.dataset.section);
      const hay = sec ? fold(`${sec.label} ${sec.group} ${SECTION_DESCRIPTIONS[sec.id] ?? ''}`) : '';
      const hit = !q || hay.includes(q);
      btn.hidden = !hit;
      if (hit) { visible++; groupsWithHits.add(btn.dataset.group || ''); }
    });
    this.container.querySelectorAll<HTMLElement>('#settings-tabs .settings-nav__group').forEach((g) => {
      g.hidden = !groupsWithHits.has(g.dataset.group || '');
    });
    const empty = this.container.querySelector<HTMLElement>('#settings-search-empty');
    if (empty) empty.hidden = visible > 0;
  }

  private loadingBlock(text: string): string {
    return `<div class="settings-loading card" role="status" aria-live="polite"><span class="spinner" aria-hidden="true"></span><span>${esc(text)}</span></div>`;
  }

  /** Presentación común: conserva los IDs, controles y handlers de cada sección. */
  private setSectionMarkup(body: HTMLElement, markup: string): void {
    const title = SETTINGS_SECTIONS.find(section => section.id === this.section)!.label;
    body.innerHTML = `<div class="settings-content" data-settings-section="${escapeAttribute(this.section)}">
      <header class="settings-heading"><h2 id="settings-section-title">${esc(title)}</h2>
        <p>${esc(SECTION_DESCRIPTIONS[this.section])}</p></header>${markup}</div>`;
    body.setAttribute('aria-busy', String(!!body.querySelector('.settings-loading')));
    body.querySelectorAll<HTMLElement>('.card').forEach(card => card.classList.add('settings-card'));
    body.querySelectorAll<HTMLElement>('[style*="var(--danger)"]').forEach(element => {
      if (element.closest('button')) return;
      element.setAttribute('role', 'alert');
      element.classList.add('settings-error');
    });
    body.querySelectorAll<HTMLElement>('[style*="var(--warning)"]').forEach(element => {
      if (!element.matches('button, .badge')) element.classList.add('settings-callout');
    });
    body.querySelectorAll<HTMLElement>('[id$="-msg"], [id$="-message"]').forEach(element => {
      element.setAttribute('role', 'status');
      element.setAttribute('aria-live', 'polite');
      element.classList.add('settings-feedback');
    });
    body.querySelectorAll<HTMLInputElement | HTMLSelectElement | HTMLTextAreaElement>('input, select, textarea').forEach(input => {
      if (input.type === 'checkbox') return;
      input.classList.add(input.tagName === 'SELECT' ? 'select' : input.tagName === 'TEXTAREA' ? 'textarea' : 'input');
      const field = input.closest('.field');
      const caption = field?.querySelector<HTMLElement>('.field__label');
      if (caption && input.id) {
        if (caption.tagName === 'LABEL') caption.setAttribute('for', input.id);
        else {
          caption.id = input.id + '-label';
          input.setAttribute('aria-labelledby', caption.id);
        }
      } else if (!input.labels?.length && !input.hasAttribute('aria-label')) {
        const labels: Record<string, string> = {
          'model-filter': 'Filtrar por proveedor o modelo', 'sel-plan-model': 'Modelo de planificación',
          'mount-input': 'Ruta de la carpeta para enlazar', 'perm-allow-input': 'Prefijo permitido',
          'perm-deny-input': 'Prefijo denegado', 'remote-token': 'Token de acceso remoto',
        };
        input.setAttribute('aria-label', labels[input.id] || input.getAttribute('placeholder') || title);
      }
      const hint = field?.querySelector<HTMLElement>('.field__hint, .card__subtitle');
      if (hint && input.id) {
        hint.id = input.id + '-hint';
        input.setAttribute('aria-describedby', hint.id);
      }
    });
    body.querySelectorAll<HTMLButtonElement>('button').forEach(button => {
      if (button.title && !button.textContent?.trim()) button.setAttribute('aria-label', button.title);
      if (button.matches('.btn-gov-mode, .btn-perm-mode, .btn-theme')) {
        button.setAttribute('aria-pressed', String(button.classList.contains('is-active') || button.style.borderColor === 'var(--accent)'));
      }
    });
    const emptyActions: Partial<Record<SettingsSection, [string, string]>> = {
      providers: ['btn-toggle-add-provider', 'Añadir proveedor'], models: ['btn-discover-models', 'Descubrir modelos'],
      skills: ['mount-browse', 'Enlazar carpeta'], plugins: ['plugins-refresh', 'Actualizar plugins'],
      memory: ['btn-settings-refresh', 'Actualizar memoria'],
    };
    body.querySelectorAll<HTMLElement>('.empty-state').forEach(empty => {
      if (!empty.querySelector('svg')) empty.insertAdjacentHTML('afterbegin', `<span aria-hidden="true">${icons.layers(22)}</span>`);
      const action = emptyActions[this.section];
      if (!action || !this.container.querySelector('#' + action[0]) || empty.querySelector('button')) return;
      const button = document.createElement('button');
      button.className = 'btn';
      button.type = 'button';
      button.textContent = action[1];
      button.addEventListener('click', () => {
        const target = this.container.querySelector<HTMLElement>('#' + action[0]);
        target?.click();
        target?.focus();
      });
      empty.appendChild(button);
    });
  }

  private async loadAndRenderSection(): Promise<void> {
    if (!this.core) return;
    switch (this.section) {
      case 'providers':
        await this.renderProvidersSection();
        break;
      case 'models':
        await this.renderModelsSection();
        break;
      case 'governance':
        await this.renderGovernanceSection();
        break;
      case 'permissions':
        await this.renderPermissionsSection();
        break;
      case 'hooks':
        this.renderHooksSection();
        break;
      case 'remote':
        await this.renderRemoteSection();
        break;
      case 'skills':
        await this.renderSkillsSection();
        break;
      case 'plugins':
        await this.renderPluginsSection();
        break;
      case 'memory':
        await this.renderMemorySection();
        break;
      case 'appearance':
        this.renderAppearanceSection();
        break;
      case 'about':
        await this.renderAboutSection();
        break;
      case 'agents':
        await this.renderAgentsSection();
        break;
      case 'rules':
        await this.renderRulesSection();
        break;
      case 'accounts':
        await this.renderAccountsSection();
        break;
    }
  }

  private async renderRemoteSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;
    this.setSectionMarkup(body, this.loadingBlock('Consultando avisos y acceso remoto…'));
    try {
      const [webhooks, remote] = await Promise.all([this.core.listWebhooks(), this.core.remoteStatus()]);
      if (this.section !== 'remote') return;
      // 8-nov (propietario): avisar de CADA orden terminada no es lo normal. Queda
      // apagado por defecto; los fallos, aprobaciones y preguntas sí avisan.
      let notifyDone = false;
      try { notifyDone = localStorage.getItem('devagents.notify.done.v1') === '1'; } catch { /* sin almacenamiento */ }
      this.setSectionMarkup(body, `<div class="col settings-remote">
        <section class="card" aria-labelledby="cabin-notice-heading">
        <h3 class="card__title" id="cabin-notice-heading">Avisos en la cabina</h3>
        <p class="card__subtitle">Los fallos, las aprobaciones pendientes y las preguntas del agente siempre avisan. Todo queda además en la campana.</p>
        <label class="settings-row" for="notify-done"><span class="settings-row__k"><b>Avisar cuando termine cada orden</b><small>Apagado por defecto: una respuesta terminada se ve en la conversación.</small></span><span class="settings-row__v"><input type="checkbox" class="sw" id="notify-done" ${notifyDone ? 'checked' : ''} /></span></label>
        </section>
        <section class="card" aria-labelledby="webhook-heading">
        <h3 class="card__title" id="webhook-heading">Avisos salientes</h3>
        <p class="card__subtitle">Windows avisa cuando DevAgents está sin foco. Los webhooks reciben aprobaciones, finales, fallos, auditoría no disponible y bloqueos por presupuesto.</p>
        <form id="webhook-form" class="settings-form-grid">
          <label>Formato <select id="webhook-format"><option value="json">Webhook JSON</option><option value="ntfy">ntfy</option></select></label>
          <label>URL del receptor o servidor ntfy <input id="webhook-url" type="url" required placeholder="https://ntfy.sh" style="width:100%"></label>
          <label>Topic de ntfy <input id="webhook-topic" maxlength="128" placeholder="mi-topic-privado" style="width:100%"></label>
          <label>Secreto HMAC opcional <input id="webhook-secret" type="password" autocomplete="new-password" maxlength="1024" style="width:100%"></label>
          <label><input id="webhook-allow-private" type="checkbox"> Permitir destinos privados para este webhook</label>
          <p id="webhook-private-hint" class="settings-callout settings-form-wide">Advertencia: permite acceder a loopback, redes privadas y metadatos al habilitar destinos privados. Actívalo solo para un receptor de confianza. Por defecto se comprueba la IP resuelta y se rechazan esos destinos; no se siguen redirecciones.</p>
          <button type="submit" class="btn btn--primary">Añadir aviso</button>
        </form>
        <p id="webhook-message" role="status"></p>
        <div id="webhook-list">${webhooks.map(h => `<div class="settings-receiver"><strong>${esc(h.format)}</strong><span>${esc(h.url)} · ${h.has_secret ? 'Con HMAC' : 'Sin HMAC'} · ${h.allow_private ? 'Advertencia: destinos privados permitidos' : 'Solo destinos públicos'}</span><div class="row"><button class="btn" data-webhook-test="${h.id}">Probar</button><button class="btn" data-webhook-delete="${h.id}">Quitar</button></div></div>`).join('') || `<div class="empty-state">${icons.webhook(22)}<span class="empty-state__title">Sin receptores configurados</span><span>Añade un receptor en el formulario para recibir los avisos.</span><button class="btn" id="webhook-empty-add" type="button">Configurar receptor</button></div>`}</div>
        </section>
        <section class="card" aria-labelledby="remote-heading">
        <h3 class="card__title" id="remote-heading">Acceso remoto</h3>
        <p class="card__subtitle">Apagado por defecto. Solo escucha en 127.0.0.1; tu túnel permite seguir órdenes desde fuera del escritorio.</p>
        <p id="remote-state" class="settings-state" role="status">${remote.running ? 'Encendido' : 'Apagado'} ${esc(remote.url)}</p>
        <div class="settings-form-grid">
        <label>Puerto (0 elige uno libre) <input id="remote-port" type="number" min="0" max="65535" value="0"></label>
        <label>Origen adicional del túnel <input id="remote-origin" type="url" placeholder="https://equipo.tailnet.ts.net" style="width:100%;max-width:640px"></label>
        </div>
        <div class="row settings-actions"><button class="btn btn--primary" id="remote-start" ${remote.running ? 'disabled' : ''}>Encender acceso remoto</button><button class="btn" id="remote-stop" ${remote.running ? '' : 'disabled'}>Apagar acceso remoto</button></div>
        <div id="remote-once" class="settings-token" hidden><p class="settings-callout">Token: se muestra una vez. Cópialo antes de cerrar esta sección.</p><input id="remote-token" type="password" readonly autocomplete="off"><div class="row settings-actions"><button class="btn" id="remote-copy">Copiar token</button><button class="btn" id="remote-hide">Descartar token</button></div></div>
        <p id="remote-message" role="status"></p>
        </section>
      </div>`);
      body.querySelector<HTMLInputElement>('#notify-done')?.addEventListener('change', (event) => {
        const on = (event.target as HTMLInputElement).checked;
        try { localStorage.setItem('devagents.notify.done.v1', on ? '1' : '0'); } catch { /* sin almacenamiento */ }
      });
      body.querySelector('#webhook-allow-private')?.setAttribute('aria-describedby', 'webhook-private-hint');
      body.querySelector('#webhook-empty-add')?.addEventListener('click', () => body.querySelector<HTMLInputElement>('#webhook-url')?.focus());
      const message = (id: string, text: string) => { const el = body.querySelector<HTMLElement>(id); if (el) el.textContent = text; };
      body.querySelector('#webhook-form')?.addEventListener('submit', async event => {
        event.preventDefault();
        const input = (id: string) => body.querySelector<HTMLInputElement>(id)!.value.trim();
        const format = body.querySelector<HTMLSelectElement>('#webhook-format')!.value as 'json' | 'ntfy';
        let url = input('#webhook-url');
        const secret = body.querySelector<HTMLInputElement>('#webhook-secret')!.value;
        try {
          if (format === 'ntfy') {
            const topic = input('#webhook-topic');
            if (!/^[A-Za-z0-9_-]{1,128}$/.test(topic)) throw new Error('Topic inválido: usa letras, números, guion o guion bajo.');
            url = url.replace(/\/$/, '') + '/' + encodeURIComponent(topic);
          }
          const allow_private = body.querySelector<HTMLInputElement>('#webhook-allow-private')!.checked;
          await this.core!.addWebhook({url, format, event: '*', allow_private, ...(secret ? {secret} : {})});
          body.querySelector<HTMLInputElement>('#webhook-secret')!.value = '';
          await this.renderRemoteSection();
        } catch (error) { message('#webhook-message', errText(error)); }
      });
      body.querySelectorAll<HTMLButtonElement>('[data-webhook-test]').forEach(button => button.addEventListener('click', async () => {
        try { await this.core!.testWebhook(Number(button.dataset.webhookTest)); message('#webhook-message', 'Prueba encolada. Comprueba la recepción y el ledger de entrega.'); }
        catch (error) { message('#webhook-message', errText(error)); }
      }));
      body.querySelectorAll<HTMLButtonElement>('[data-webhook-delete]').forEach(button => button.addEventListener('click', async () => {
        try { await this.core!.deleteWebhook(Number(button.dataset.webhookDelete)); await this.renderRemoteSection(); }
        catch (error) { message('#webhook-message', errText(error)); }
      }));
      body.querySelector('#remote-start')?.addEventListener('click', async () => {
        const button = body.querySelector<HTMLButtonElement>('#remote-start')!;
        button.disabled = true;
        try {
          const port = Number(body.querySelector<HTMLInputElement>('#remote-port')!.value);
          const origin = body.querySelector<HTMLInputElement>('#remote-origin')!.value.trim();
          const result = await this.core!.remoteStart(port, origin);
          message('#remote-state', 'Encendido ' + result.url);
          body.querySelector<HTMLInputElement>('#remote-token')!.value = result.token;
          body.querySelector<HTMLElement>('#remote-once')!.hidden = false;
          body.querySelector<HTMLButtonElement>('#remote-stop')!.disabled = false;
        } catch (error) { button.disabled = false; message('#remote-message', errText(error)); }
      });
      const clearToken = () => { body.querySelector<HTMLInputElement>('#remote-token')!.value = ''; body.querySelector<HTMLElement>('#remote-once')!.hidden = true; };
      body.querySelector('#remote-hide')?.addEventListener('click', clearToken);
      body.querySelector('#remote-copy')?.addEventListener('click', async () => {
        try { await navigator.clipboard.writeText(body.querySelector<HTMLInputElement>('#remote-token')!.value); message('#remote-message', 'Token copiado.'); }
        catch (error) { message('#remote-message', 'No se pudo copiar: ' + errText(error)); }
      });
      body.querySelector('#remote-stop')?.addEventListener('click', async () => {
        try { await this.core!.remoteStop(); clearToken(); await this.renderRemoteSection(); }
        catch (error) { message('#remote-message', errText(error)); }
      });
    } catch (error) { this.setSectionMarkup(body, `<div class="card settings-error" role="alert">No se pueden consultar los avisos: ${esc(errText(error))}</div>`); }
  }

  // -------------------------------------------------------------- Proveedores

  private async renderProvidersSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;

    if (!this.providersLoaded) {
      this.setSectionMarkup(body, this.loadingBlock('Cargando proveedores y claves…'));
      try {
        const [providers, keys] = await Promise.all([this.core.listProviders(), this.core.listKeys()]);
        this.providers = providers;
        this.keys = keys;
        this.providersError = null;
      } catch (e) {
        this.providersError = errText(e);
      }
      this.providersLoaded = true;
    }

    this.setSectionMarkup(body, this.providersMarkup());
    this.bindProvidersEvents(body);
  }

  private providersMarkup(): string {
    const errBlock = this.providersError
      ? `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">${esc(this.providersError)}</span></div>`
      : '';

    const providerRows = this.providers.length
      ? this.providers
          .map((p) => {
            const keyCount = p.keys?.length ?? 0;
            const modelCount = p.models?.length ?? 0;
            // QA primerizo (11-nov): las filas no respondían al clic. Ahora
            // eligen ese proveedor en «Añadir clave» y llevan al formulario.
            return `
            <div class="list-item provider-row" role="button" tabindex="0" style="cursor:pointer" data-provider-row="${escapeAttribute(p.name)}"
                 title="Añadir o cambiar la clave de ${escapeAttribute(p.name)}">
              <span class="list-item__icon">${icons.provider(14)}</span>
              <div class="grow col" style="gap:2px">
                <div class="row" style="gap:8px">
                  <span style="font-weight:600;color:var(--fg)">${esc(p.name)}</span>
                  <span class="badge ${p.is_free_tier ? 'badge--success' : 'badge--warning'}">${p.is_free_tier ? 'gratis' : 'pago'}</span>
                  <span class="badge">${esc(p.api_style)}</span>
                </div>
                <span class="subtle truncate">${esc(p.base_url || '—')}</span>
                ${/^opencode$/i.test(p.name) ? `<span class="subtle" style="font-size:11px;white-space:normal">${esc(OPENCODE_FREE_NOTE)}</span>` : ''}
              </div>
              <span class="list-item__meta">${keyCount} clave${keyCount === 1 ? '' : 's'} · ${modelCount} modelo${modelCount === 1 ? '' : 's'}</span>
            </div>`;
          })
          .join('')
      : `<div class="empty-state">${icons.provider(22)}<span class="empty-state__title">Sin proveedores registrados</span><span>Añade uno con los atajos de arriba o el formulario de proveedor personalizado.</span></div>`;

    const providerOptions = this.providers
      .map((p) => `<option value="${escapeAttribute(p.name)}" ${p.name === this.preselectProvider ? 'selected' : ''}>${esc(p.name)}</option>`)
      .join('');

    const defaultSuggestBase = this.preselectProvider || this.providers[0]?.name || '';
    const suggested = defaultSuggestBase ? suggestLabel(defaultSuggestBase, this.keys) : '';

    const keyRows = this.keys.length
      ? this.keys
          .map((k) => {
            const statusClass =
              k.status === 'error' ? 'badge--danger' : k.status === 'cooling' ? 'badge--warning' : 'badge--success';
            const priority = k.priority ?? 0;
            const qLimit = k.quota_limit ?? 0;
            const qUsed = k.quota_used ?? 0;
            const reqs = k.requests_count ?? 0;
            const quotaText = qLimit > 0 ? `${qUsed}/${qLimit}` : `${qUsed} usadas`;
            return `
            <div class="list-item" style="cursor:default">
              <span class="list-item__icon">${icons.key(14)}</span>
              <span class="list-item__label">
                <span style="font-weight:600">${esc(k.label)}</span> <span class="subtle">(${esc(k.provider)})</span>
                <span class="subtle" style="font-size:11px;display:block">prioridad ${priority} · cuota ${esc(quotaText)} · ${reqs} llamadas</span>
              </span>
              ${k.in_use ? '<span class="badge badge--info" title="Clave que está sirviendo las llamadas ahora">en uso</span>' : ''}
              <span class="badge ${statusClass}">${esc(k.status || 'activa')}</span>
              <button class="icon-btn btn-edit-key" data-provider="${escapeAttribute(k.provider)}" data-label="${escapeAttribute(k.label)}" data-priority="${priority}" data-quota="${qLimit}" title="Editar prioridad y cuota">${icons.settings(14)}</button>
              <button class="icon-btn btn-remove-key" data-provider="${escapeAttribute(k.provider)}" data-label="${escapeAttribute(k.label)}" title="Borrar clave">${icons.trash(14)}</button>
            </div>`;
          })
          .join('')
      : `<div class="empty-state">${icons.key(20)}<span>Sin claves registradas todavía.</span></div>`;

    const keyMsg = this.keyFormMsg
      ? `<span style="color:${this.keyFormMsg.type === 'ok' ? 'var(--success)' : 'var(--danger)'}">${esc(this.keyFormMsg.text)}</span>`
      : '<span></span>';

    const connectOfferBlock = this.connectOffer
      ? `<div class="card row" style="justify-content:space-between;align-items:center;border-color:var(--warning);gap:12px">
          <span class="row" style="gap:8px;color:var(--warning)">${icons.alert(14)}<span>El proveedor "${esc(this.connectOffer.name)}" no está registrado todavía.</span></span>
          <button class="btn btn--sm btn--primary" id="btn-create-connect-provider" title="Registrar un proveedor nuevo y guardar su clave">Crear proveedor ahora</button>
        </div>`
      : '';

    const addProviderMsgHtml = this.addProviderMsg
      ? `<span style="color:${this.addProviderMsg.type === 'ok' ? 'var(--success)' : 'var(--danger)'}">${esc(this.addProviderMsg.text)}</span>`
      : '<span></span>';

    const addProviderBlock = `
      <div class="card">
        <button class="btn btn--ghost" id="btn-toggle-add-provider" title="Mostrar u ocultar el formulario para añadir un proveedor" style="justify-content:flex-start;width:100%">
          ${this.addProviderOpen ? icons.chevronDown(14) : icons.chevronRight(14)}
          <span>Añadir proveedor personalizado</span>
        </button>
        <form id="form-add-provider" class="col" style="gap:10px;margin-top:10px;${this.addProviderOpen ? '' : 'display:none'}">
          <div class="field">
            <label class="field__label">Nombre</label>
            <input class="input" id="np-name" placeholder="mi_proveedor" />
          </div>
          <div class="field">
            <label class="field__label">Estilo de API</label>
            <select class="select" id="np-style">
              <option value="openai">openai</option>
              <option value="anthropic">anthropic</option>
              <option value="gemini">gemini</option>
              <option value="ollama">ollama</option>
            </select>
          </div>
          <div class="field">
            <label class="field__label">URL base</label>
            <input class="input" id="np-url" placeholder="https://api.miproveedor.com" />
          </div>
          <div class="row" style="justify-content:space-between;align-items:center">
            ${addProviderMsgHtml}
            <button type="submit" class="btn btn--primary" title="Registrar el proveedor con los datos del formulario">Añadir proveedor</button>
          </div>
        </form>
      </div>`;

    return `
      <div class="col" style="gap:16px">
        ${errBlock}
        <div class="row" style="gap:8px;flex-wrap:wrap">
          <button class="btn btn--primary" id="btn-connect-claude" title="Conectar Anthropic (Claude) con una clave API">${icons.bolt(14)}<span>Conectar Claude (Anthropic)</span></button>
          <button class="btn btn--primary" id="btn-connect-gemini" title="Conectar Google Gemini con una clave API">${icons.bolt(14)}<span>Conectar Google Gemini</span></button>
        </div>

        ${connectOfferBlock}

        <div class="card">
          <div class="card__title">Proveedores registrados</div>
          <div class="card__subtitle">Disponibilidad, tipo de API y cuentas conectadas para cada proveedor.</div>
          <div class="col" style="gap:6px;margin-top:10px">${providerRows}</div>
        </div>

        <div class="card">
          <div class="card__title">Añadir clave API</div>
          <div class="card__subtitle">
            Multi-cuenta: puedes registrar varias claves para el mismo proveedor usando etiquetas distintas
            (por ejemplo GEMINI_01, GEMINI_02). El motor rota automáticamente entre ellas cuando una recibe un error 429.
          </div>
          <form id="form-add-key" class="col" style="gap:10px;margin-top:10px">
            <div class="field">
              <label class="field__label">Proveedor</label>
              <select class="select" id="key-provider">${providerOptions || '<option value="">Sin proveedores</option>'}</select>
            </div>
            <div class="field">
              <label class="field__label">Etiqueta de la cuenta</label>
              <input class="input" id="key-label" placeholder="GEMINI_01" value="${escapeAttribute(suggested)}" />
              <span class="field__hint">Etiqueta libre sugerida automáticamente a partir de las claves existentes; cámbiala si prefieres otra.</span>
            </div>
            <div class="field">
              <label class="field__label">Clave API</label>
              <input class="input" type="password" id="key-value" placeholder="sk-..." autocomplete="off" />
            </div>
            <div class="row" style="justify-content:space-between;align-items:center">
              ${keyMsg}
              <button type="submit" class="btn btn--primary" title="Guardar la clave API de este proveedor" ${this.providers.length ? '' : 'disabled'}>Guardar clave</button>
            </div>
          </form>
        </div>

        <div class="card">
          <div class="card__title">Claves registradas</div>
          <div class="card__subtitle">Gestiona la prioridad y el cupo de cada cuenta sin mostrar su clave.</div>
          <div class="col" style="gap:6px;margin-top:10px">${keyRows}</div>
        </div>

        ${addProviderBlock}
      </div>`;
  }

  private bindProvidersEvents(body: HTMLElement): void {
    const providerSel = body.querySelector<HTMLSelectElement>('#key-provider');
    const labelInput = body.querySelector<HTMLInputElement>('#key-label');
    const keyInput = body.querySelector<HTMLInputElement>('#key-value');

    providerSel?.addEventListener('change', () => {
      this.preselectProvider = providerSel.value;
      if (labelInput) labelInput.value = suggestLabel(providerSel.value, this.keys);
    });

    const pickProvider = (name: string): void => {
      if (!providerSel || !name) return;
      providerSel.value = name;
      this.preselectProvider = name;
      if (labelInput) labelInput.value = suggestLabel(name, this.keys);
      const form = body.querySelector<HTMLElement>('#form-add-key');
      form?.scrollIntoView?.({ behavior: 'smooth', block: 'center' });
      keyInput?.focus();
    };
    body.querySelectorAll<HTMLElement>('[data-provider-row]').forEach((row) => {
      row.addEventListener('click', () => pickProvider(row.dataset.providerRow || ''));
      row.addEventListener('keydown', (ev) => {
        if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); pickProvider(row.dataset.providerRow || ''); }
      });
    });

    body.querySelector<HTMLFormElement>('#form-add-key')?.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      if (!this.core) return;
      const provider = providerSel?.value || '';
      const label = labelInput?.value.trim() || '';
      const key = keyInput?.value || '';
      if (!provider || !label || !key) {
        this.keyFormMsg = { type: 'error', text: 'Completa proveedor, etiqueta y clave antes de guardar.' };
        this.setSectionMarkup(body, this.providersMarkup());
        this.bindProvidersEvents(body);
        return;
      }
      try {
        await this.core.addKey(provider, label, key);
        // USUARIO-NUEVO A5 (10-nov): con la clave de OpenCode se esperan sus
        // modelos gratuitos, que por esta vía no aparecen.
        this.keyFormMsg = { type: 'ok', text: `Clave "${label}" guardada para ${provider}.${/^opencode$/i.test(provider) ? ' ' + OPENCODE_FREE_NOTE : ''}` };
        this.connectOffer = null;
        this.providersLoaded = false;
        await this.renderProvidersSection();
      } catch (e) {
        this.keyFormMsg = { type: 'error', text: errText(e) };
        this.setSectionMarkup(body, this.providersMarkup());
        this.bindProvidersEvents(body);
      }
    });

    body.querySelectorAll<HTMLElement>('.btn-edit-key').forEach((btn) => {
      btn.addEventListener('click', async () => {
        if (!this.core) return;
        const provider = btn.dataset.provider || '';
        const label = btn.dataset.label || '';
        const curPriority = btn.dataset.priority || '0';
        const curQuota = btn.dataset.quota || '0';
        const prStr = window.prompt(`Prioridad de "${label}" (mayor = se intenta antes). Actual: ${curPriority}`, curPriority);
        if (prStr === null) return;
        const priority = parseInt(prStr, 10);
        if (isNaN(priority) || priority < 0) {
          this.keyFormMsg = { type: 'error', text: 'La prioridad debe ser un número mayor o igual a 0.' };
          this.setSectionMarkup(body, this.providersMarkup());
          this.bindProvidersEvents(body);
          return;
        }
        const qStr = window.prompt(`Cuota máxima de "${label}" por ventana (0 = sin tope). Actual: ${curQuota}`, curQuota);
        if (qStr === null) return;
        const quotaLimit = parseInt(qStr, 10);
        if (isNaN(quotaLimit) || quotaLimit < 0) {
          this.keyFormMsg = { type: 'error', text: 'La cuota debe ser un número mayor o igual a 0.' };
          this.setSectionMarkup(body, this.providersMarkup());
          this.bindProvidersEvents(body);
          return;
        }
        try {
          await this.core.setKeyMeta(provider, label, { priority, quotaLimit });
          this.keyFormMsg = { type: 'ok', text: `"${label}": prioridad ${priority}, cuota ${quotaLimit > 0 ? quotaLimit : 'sin tope'}.` };
          this.providersLoaded = false;
          await this.renderProvidersSection();
        } catch (e) {
          this.keyFormMsg = { type: 'error', text: errText(e) };
          this.setSectionMarkup(body, this.providersMarkup());
          this.bindProvidersEvents(body);
        }
      });
    });

    body.querySelectorAll<HTMLElement>('.btn-remove-key').forEach((btn) => {
      btn.addEventListener('click', async () => {
        if (!this.core) return;
        const provider = btn.dataset.provider || '';
        const label = btn.dataset.label || '';
        try {
          await this.core.removeKey(provider, label);
          this.keyFormMsg = { type: 'ok', text: `Clave "${label}" eliminada.` };
          this.providersLoaded = false;
          await this.renderProvidersSection();
        } catch (e) {
          this.keyFormMsg = { type: 'error', text: errText(e) };
          this.setSectionMarkup(body, this.providersMarkup());
          this.bindProvidersEvents(body);
        }
      });
    });

    body.querySelector('#btn-connect-claude')?.addEventListener('click', () => {
      void this.handleConnectShortcut('claude');
    });
    body.querySelector('#btn-connect-gemini')?.addEventListener('click', () => {
      void this.handleConnectShortcut('gemini');
    });

    body.querySelector('#btn-create-connect-provider')?.addEventListener('click', async () => {
      if (!this.core || !this.connectOffer) return;
      const offer = this.connectOffer;
      try {
        await this.core.addProvider(offer.name, offer.apiStyle, offer.baseUrl);
        this.connectOffer = null;
        this.preselectProvider = offer.name;
        this.providersLoaded = false;
        await this.renderProvidersSection();
        this.focusKeyField(offer.name);
      } catch (e) {
        this.addProviderMsg = { type: 'error', text: errText(e) };
        this.setSectionMarkup(body, this.providersMarkup());
        this.bindProvidersEvents(body);
      }
    });

    body.querySelector('#btn-toggle-add-provider')?.addEventListener('click', () => {
      this.addProviderOpen = !this.addProviderOpen;
      this.setSectionMarkup(body, this.providersMarkup());
      this.bindProvidersEvents(body);
    });

    body.querySelector<HTMLFormElement>('#form-add-provider')?.addEventListener('submit', async (ev) => {
      ev.preventDefault();
      if (!this.core) return;
      const name = (body.querySelector<HTMLInputElement>('#np-name')?.value || '').trim();
      const apiStyle = body.querySelector<HTMLSelectElement>('#np-style')?.value || 'openai';
      const baseUrl = (body.querySelector<HTMLInputElement>('#np-url')?.value || '').trim();
      if (!name || !baseUrl) {
        this.addProviderMsg = { type: 'error', text: 'Nombre y URL base son obligatorios.' };
        this.setSectionMarkup(body, this.providersMarkup());
        this.bindProvidersEvents(body);
        return;
      }
      try {
        await this.core.addProvider(name, apiStyle, baseUrl);
        this.addProviderMsg = { type: 'ok', text: `Proveedor "${name}" añadido.` };
        this.addProviderOpen = false;
        this.providersLoaded = false;
        await this.renderProvidersSection();
      } catch (e) {
        this.addProviderMsg = { type: 'error', text: errText(e) };
        this.setSectionMarkup(body, this.providersMarkup());
        this.bindProvidersEvents(body);
      }
    });
  }

  /** Busca (o propone crear) el proveedor Claude/Gemini y enfoca el formulario de clave. */
  private async handleConnectShortcut(kind: 'claude' | 'gemini'): Promise<void> {
    const patterns = kind === 'claude' ? ['anthropic', 'claude'] : ['google', 'gemini'];
    const match = this.providers.find((p) => patterns.some((pat) => p.name.toLowerCase().includes(pat)));

    if (match) {
      this.connectOffer = null;
      this.preselectProvider = match.name;
      await this.renderProvidersSection();
      this.focusKeyField(match.name);
      return;
    }

    const defaults =
      kind === 'claude'
        ? { name: 'anthropic', apiStyle: 'anthropic', baseUrl: 'https://api.anthropic.com' }
        : { name: 'google_gemini', apiStyle: 'gemini', baseUrl: 'https://generativelanguage.googleapis.com' };
    this.connectOffer = { kind, ...defaults };
    await this.renderProvidersSection();
  }

  private focusKeyField(providerName: string): void {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body) return;
    const sel = body.querySelector<HTMLSelectElement>('#key-provider');
    const labelInput = body.querySelector<HTMLInputElement>('#key-label');
    const keyInput = body.querySelector<HTMLInputElement>('#key-value');
    if (sel) sel.value = providerName;
    if (labelInput) labelInput.value = suggestLabel(providerName, this.keys);
    keyInput?.scrollIntoView({ behavior: 'smooth', block: 'center' });
    keyInput?.focus();
  }

  // ------------------------------------------------------------------ Modelos

  private async renderModelsSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;

    if (!this.modelsLoaded) {
      this.setSectionMarkup(body, this.loadingBlock('Cargando catálogo de modelos…'));
      try {
        const [providers, catalog, plan, selection, external, governance] = await Promise.all([
          this.core.listProviders(),
          this.core.catalogInfo(),
          this.core.getPlanModel(),
          this.core.modelSelection(),
          this.core.getExternalAgents(),
          this.core.getGovernance(),
        ]);
        this.providers = providers;
        this.catalog = catalog;
        this.planModel = plan;
        this.selectionRows = selection;
        this.externalModels = external;
        this.governanceMode = governance.mode;
        this.modelsError = null;

        // Si hay proveedores con clave pero el catálogo está vacío, se descubre
        // una sola vez sin pedirlo. El motor solo puebla la tabla `models` al
        // llamar a `da_models_discover`, y el usuario no tiene por qué saber
        // que existe ese paso: llegaba a Modelos, veía la tabla vacía y
        // concluía que su clave no servía.
        const hasKeys = providers.some((p) => (p.keys || []).length > 0);
        const hasModels = providers.some((p) => (p.models || []).length > 0);
        if (hasKeys && !hasModels && !this.autoDiscoverTried) {
          this.autoDiscoverTried = true;
          try {
            const res = await this.core.discoverModels();
            this.providers = await this.core.listProviders();
            this.catalog = await this.core.catalogInfo();
            this.selectionRows = await this.core.modelSelection();
            this.modelsMsg = {
              type: 'ok',
              text: `Catálogo vacío: se descubrieron ${res.count} modelo(s) automáticamente.`,
            };
          } catch (error) {
            this.modelsMsg = { type: 'error', text: 'No se pudo descubrir el catálogo: ' + errText(error) };
          }
        }
      } catch (e) {
        this.modelsError = errText(e);
      }
      this.modelsLoaded = true;
    }

    this.setSectionMarkup(body, this.modelsMarkup());
    this.bindModelsEvents(body);
  }

  private modelsMarkup(): string {
    const errBlock = this.modelsError
      ? `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">${esc(this.modelsError)}</span></div>`
      : '';
    const msgBlock = this.modelsMsg
      ? `<span style="color:${this.modelsMsg.type === 'ok' ? 'var(--success)' : 'var(--danger)'}">${esc(this.modelsMsg.text)}</span>`
      : '<span></span>';

    const stats = this.catalog
      ? `
      <div class="row" style="gap:24px;flex-wrap:wrap">
        <div class="col" style="gap:2px"><span class="section-label">Ruta del catálogo</span><span class="mono truncate" style="max-width:360px;display:block">${esc(this.catalog.catalog_path_abs)}</span></div>
        <div class="col" style="gap:2px" title="Modelos de la tabla marcados como disponibles frente al total"><span class="section-label">Modelos</span><span id="model-count-stat">${esc(this.modelCountStat())}</span></div>
        <div class="col" style="gap:2px"><span class="section-label">Proveedores</span><span>${esc(this.catalog.provider_count)}</span></div>
        <div class="col" style="gap:2px"><span class="section-label">Claves</span><span>${esc(this.catalog.key_count)}</span></div>
      </div>`
      : '<span class="subtle">Sin datos de catálogo.</span>';

    const options = [`<option value="" ${!this.planModel.provider ? 'selected' : ''}>Automático (router)</option>`]
      .concat(
        this.providers.flatMap((p) =>
          (p.models || []).filter(m => {
            const metadata = this.selectionRows.find(r => r.provider === p.name && r.model === m.name);
            return (metadata?.text_gen ?? m.text_gen) !== false && metadata?.show_in_selectors !== false &&
              (this.governanceMode === 'local' ? p.local === true : this.governanceMode === 'free' ? (metadata?.is_free ?? m.is_free) : true);
          }).map((m) => {
            const modelName = m.name || '';
            const val = `${p.name}|${modelName}`;
            const selected = p.name === this.planModel.provider && modelName === this.planModel.model ? 'selected' : '';
            return `<option value="${escapeAttribute(val)}" ${selected}>${esc(p.name)} — ${esc(modelName)}</option>`;
          })
        )
      )
      .join('');

    const pinnedValue = `${this.planModel.provider}|${this.planModel.model}`;
    const hiddenPin = this.planModel.provider && !options.includes(`value="${escapeAttribute(pinnedValue)}"`)
      ? `<option value="${escapeAttribute(pinnedValue)}" selected>${esc(pinnedValue)} · fijado a mano (fuera de la lista visible)</option>` : '';

    return `
      <div class="col" style="gap:16px">
        ${errBlock}
        <div class="card">
          <div class="row" style="justify-content:space-between;align-items:center">
            <div class="card__title">Catálogo de modelos</div>
            <button class="btn" id="btn-discover-models" title="Sondear el catálogo del proveedor y actualizar la lista de modelos">${icons.refresh(14)}<span>Descubrir modelos</span></button>
          </div>
          <div class="card__subtitle">Actualiza los modelos que ofrecen tus proveedores conectados.</div>
          <div style="margin-top:10px">${stats}</div>
          <div class="row" style="margin-top:8px">${msgBlock}</div>
        </div>

        <div class="card">
          <div class="card__title">Modelo de planificación</div>
          <div class="card__subtitle">Fija el modelo que planifica cada orden, o deja el router automático elegir según gobernanza y salud de proveedores.</div>
          <select class="select" id="sel-plan-model" style="margin-top:10px">${options}${hiddenPin}</select>
        </div>

        <div class="card">
          <div class="row" style="justify-content:space-between;align-items:center">
            <div class="card__title">Tabla del catálogo</div>
            <span class="subtle" id="model-count-label" style="font-size:11px">${this.filteredModelRows().length} de ${this.modelRows().length} modelo(s)</span>
          </div>
          <div class="card__subtitle">Cada modelo tiene dos permisos independientes. Un modelo fijado a mano sigue funcionando aunque esté oculto o excluido del reparto automático; la gobernanza y la capacidad de texto siguen aplicándose.</div>
          <div class="field" style="margin-top:10px">
            <input class="input" id="model-filter" placeholder="Filtrar por proveedor o modelo…" value="${escapeAttribute(this.modelsFilter)}" />
          </div>
          <div style="margin-top:10px;max-height:420px;overflow:auto;border:1px solid var(--border);border-radius:var(--radius-sm)">
            <table style="width:100%;border-collapse:collapse;font-size:12px">
              <thead>
                <tr>
                  ${['Proveedor', 'Modelo', 'Contexto', 'Gratis', 'Disponible', 'Favorito', 'Mostrar en selectores', 'Permitir al router y al enjambre']
                    .map(
                      (h) =>
                        `<th style="position:sticky;top:0;background:var(--surface-2);text-align:left;padding:6px 10px;border-bottom:1px solid var(--border)">${h}</th>`
                    )
                    .join('')}
                </tr>
              </thead>
              <tbody id="model-table-body">${this.modelsTableBodyMarkup()}</tbody>
            </table>
          </div>
        </div>
      </div>`;
  }

  /** Aplana `ProviderInfo[]` a filas proveedor+modelo, tal como las lista el catálogo. */
  /**
   * QA primerizo (11-nov): la cifra decía «MODELOS 0» con 178 filas en la
   * tabla — contaba solo modelos de proveedores con fila disponible en el
   * catálogo, sin agentes externos. Ahora cuenta la misma tabla que se ve.
   */
  private modelCountStat(): string {
    const rows = this.modelRows();
    if (!rows.length) return String(this.catalog?.model_count ?? 0);
    const usable = rows.filter((r) => r.model.available !== false).length;
    return usable === rows.length ? String(rows.length) : `${usable} disponibles de ${rows.length}`;
  }

  private modelRows(): Array<{ provider: string; model: ProviderModel }> {
    const rows: Array<{ provider: string; model: ProviderModel }> = [];
    this.providers.forEach((p) => {
      (p.models || []).forEach((m) => rows.push({ provider: p.name, model: m }));
    });
    for (const agent of this.externalModels) {
      for (const model of agent.models || []) rows.push({ provider: agent.provider, model: {
        name: model.slug, is_free: model.free === true || (agent.provider !== 'agent:opencode' && agent.session === 'suscripcion'),
        available: model.free === true || agent.session === 'suscripcion', text_gen: model.text_gen,
      } });
    }
    return rows;
  }

  private filteredModelRows(): Array<{ provider: string; model: ProviderModel }> {
    const q = this.modelsFilter.trim().toLowerCase();
    const rows = this.modelRows();
    if (!q) return rows;
    return rows.filter(
      (r) => r.provider.toLowerCase().includes(q) || (r.model.name || '').toLowerCase().includes(q)
    );
  }

  private modelsTableBodyMarkup(): string {
    const rows = this.filteredModelRows();
    if (!rows.length) {
      const hasAny = this.modelRows().length > 0;
      return `<tr><td colspan="8" style="padding:0">
        <div class="empty-state">
          ${icons.layers(22)}
          <span class="empty-state__title">${hasAny ? 'Ningún modelo coincide con el filtro' : 'Sin modelos en el catálogo'}</span>
          <span>${hasAny ? 'Prueba con otro proveedor o nombre de modelo.' : 'Pulsa "Descubrir modelos" arriba para poblar el catálogo desde los proveedores con clave.'}</span>
        </div>
      </td></tr>`;
    }
    return rows
      .map((r, i) => {
        const m = r.model;
        const ctx =
          m.context_window === null || m.context_window === undefined
            ? '—'
            : formatThousands(m.context_window);
        const badge = (yes: boolean) => (yes ? '<span class="badge badge--success">sí</span>' : '<span class="badge">no</span>');
        const rowBg = i % 2 === 1 ? 'background:var(--surface-1)' : '';
        // El favorito ya SÍ se puede elegir: `da_model_set_favorite` escribe el
        // mismo campo que el router usa para ordenar candidatos.
        const on = !!m.is_favorite;
        const fav = `<button class="icon-btn btn-fav" data-provider="${escapeAttribute(r.provider)}" data-model="${escapeAttribute(m.name || '')}"
          data-on="${on ? '1' : '0'}" title="${on ? 'Quitar de favoritos' : 'Marcar como favorito'}"
          style="color:${on ? 'var(--warning)' : 'var(--fg-subtle)'}">${on ? '★' : '☆'}</button>`;
        const preferences = this.selectionRows.find(row => row.provider === r.provider && row.model === m.name);
        const toggle = (field: 'show_in_selectors' | 'allow_automatic', label: string) => `<input type="checkbox" role="switch" class="model-preference-toggle" data-provider="${escapeAttribute(r.provider)}" data-model="${escapeAttribute(m.name || '')}" data-field="${field}" aria-label="${escapeAttribute(`${label}: ${r.provider} / ${m.name}`)}" ${preferences?.[field] !== false ? 'checked' : ''} />`;
        return `<tr style="${rowBg}">
          <td style="padding:6px 10px">${esc(r.provider)}</td>
          <td style="padding:6px 10px" class="mono">${esc(m.name || '—')}</td>
          <td style="padding:6px 10px">${esc(ctx)}</td>
          <td style="padding:6px 10px">${badge(preferences?.is_free ?? !!m.is_free)}</td>
          <td style="padding:6px 10px">${badge(!!m.available)}</td>
          <td style="padding:6px 10px">${r.provider.startsWith('agent:') ? '—' : fav}</td>
          <td style="padding:6px 10px">${toggle('show_in_selectors', 'Mostrar en selectores')}</td>
          <td style="padding:6px 10px">${toggle('allow_automatic', 'Permitir al router y al enjambre')}</td>
        </tr>`;
      })
      .join('');
  }

  /**
   * Ata las estrellas de la columna Favorito.
   *
   * Se llama tras cada repintado del `<tbody>`, no una sola vez: el filtro
   * reemplaza esas filas y los listeners se irían con ellas.
   */
  private bindFavoriteButtons(body: HTMLElement): void {
    body.querySelectorAll<HTMLElement>('.btn-fav').forEach((el) => {
      el.addEventListener('click', async () => {
        if (!this.core) return;
        const provider = el.dataset.provider || '';
        const model = el.dataset.model || '';
        const next = el.dataset.on !== '1';
        try {
          await this.core.setModelFavorite(provider, model, next);
          // Se refleja en el modelo en memoria para no recargar el catálogo
          // entero por una estrella.
          this.providers.forEach((p) => {
            if (p.name !== provider) return;
            (p.models || []).forEach((m) => {
              if (m.name === model) m.is_favorite = next;
            });
          });
          const tbody = body.querySelector<HTMLElement>('#model-table-body');
          if (tbody) {
            tbody.innerHTML = this.modelsTableBodyMarkup();
            this.bindFavoriteButtons(body);
            this.bindModelPreferenceToggles(body);
          }
        } catch (e) {
          this.modelsMsg = { type: 'error', text: errText(e) };
          this.setSectionMarkup(body, this.modelsMarkup());
          this.bindModelsEvents(body);
        }
      });
    });
  }

  private bindModelPreferenceToggles(body: HTMLElement): void {
    body.querySelectorAll<HTMLInputElement>('.model-preference-toggle').forEach(input => {
      input.addEventListener('change', async () => {
        if (!this.core) return;
        const provider = input.dataset.provider || '';
        const model = input.dataset.model || '';
        const field = input.dataset.field;
        if (field !== 'show_in_selectors' && field !== 'allow_automatic') return;
        const previous = this.selectionRows.find(r => r.provider === provider && r.model === model);
        const show = field === 'show_in_selectors' ? input.checked : previous?.show_in_selectors !== false;
        const allow = field === 'allow_automatic' ? input.checked : previous?.allow_automatic !== false;
        // Freeze both switches until their shared pair has been persisted.
        body.querySelectorAll<HTMLInputElement>('.model-preference-toggle').forEach(el => el.disabled = true);
        try {
          const check = await this.core.setModelPreferences(provider, model, show, allow);
          if (previous) Object.assign(previous, { show_in_selectors: show, allow_automatic: allow });
          else this.selectionRows.push({ provider, model, text_gen: true, is_free: false, show_in_selectors: show, allow_automatic: allow });
          document.dispatchEvent(new CustomEvent('devagents:models-changed'));
          const warning = check.issues.find(i => i.cause === 'audit_unavailable_by_preferences');
          this.modelsMsg = warning
            ? { type: 'error', text: `${warning.reason}. ${warning.action}.` }
            : { type: 'ok', text: 'Preferencias guardadas. Los modelos fijados a mano se conservan.' };
        } catch (error) {
          this.modelsMsg = { type: 'error', text: 'No se guardaron las preferencias: ' + errText(error) };
        }
        this.setSectionMarkup(body, this.modelsMarkup());
        this.bindModelsEvents(body);
      });
    });
  }

  private bindModelsEvents(body: HTMLElement): void {
    this.bindFavoriteButtons(body);
    this.bindModelPreferenceToggles(body);
    // Solo se repinta el <tbody>: reemplazar toda la sección en cada pulsación
    // le haría perder el foco al campo de filtro.
    const filterInput = body.querySelector<HTMLInputElement>('#model-filter');
    filterInput?.addEventListener('input', () => {
      this.modelsFilter = filterInput.value;
      const tbody = body.querySelector<HTMLElement>('#model-table-body');
      if (tbody) {
        tbody.innerHTML = this.modelsTableBodyMarkup();
        this.bindFavoriteButtons(body);
        this.bindModelPreferenceToggles(body);
      }
      const countLabel = body.querySelector<HTMLElement>('#model-count-label');
      if (countLabel) countLabel.textContent = `${this.filteredModelRows().length} de ${this.modelRows().length} modelo(s)`;
    });

    body.querySelector('#btn-discover-models')?.addEventListener('click', async () => {
      if (!this.core) return;
      try {
        const res = await this.core.discoverModels();
        this.modelsMsg = { type: 'ok', text: `Se descubrieron ${res.count} modelo(s).` };
        this.modelsLoaded = false;
        await this.renderModelsSection();
      } catch (e) {
        this.modelsMsg = { type: 'error', text: errText(e) };
        this.setSectionMarkup(body, this.modelsMarkup());
        this.bindModelsEvents(body);
      }
    });

    body.querySelector<HTMLSelectElement>('#sel-plan-model')?.addEventListener('change', async (ev) => {
      if (!this.core) return;
      const val = (ev.target as HTMLSelectElement).value;
      const [provider, model] = val ? val.split('|') : ['', ''];
      try {
        await this.core.setPlanModel(provider || '', model || '');
        this.planModel = { provider: provider || '', model: model || '' };
        // B2/E2.4: el compositor escucha este evento y relee los pines del
        // motor — sin él su selector se quedaba mostrando el pin viejo.
        document.dispatchEvent(new CustomEvent('devagents:models-changed'));
        this.modelsMsg = {
          type: 'ok',
          text: provider
            ? `Modelo de planificación fijado a ${provider} / ${model}.`
            : 'Modelo de planificación devuelto al router automático.',
        };
      } catch (e) {
        this.modelsMsg = { type: 'error', text: errText(e) };
      }
      this.setSectionMarkup(body, this.modelsMarkup());
      this.bindModelsEvents(body);
    });
  }

  // -------------------------------------------------------------- Gobernanza

  private async renderGovernanceSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;

    if (!this.governanceLoaded) {
      this.setSectionMarkup(body, this.loadingBlock('Cargando modo de gobernanza…'));
      try {
        const res = await this.core.getGovernance();
        this.governanceMode = res.mode;
        this.governanceError = null;
      } catch (e) {
        this.governanceError = errText(e);
      }
      // E1.18 + E1.16: presupuesto y medidor semanal viajan con la misma
      // sección — son la parte del modo que el usuario tiene que poder ver.
      try {
        this.budget = await this.core.getBudget();
        this.budgetError = null;
      } catch (error) {
        this.budget = null;
        this.budgetError = 'No se pudo consultar el presupuesto: ' + errText(error);
      }
      try {
        this.usageWeek = await this.core.getUsageWeek();
        this.usageWeekError = null;
      } catch (error) {
        this.usageWeek = null;
        this.usageWeekError = 'No se pudo consultar el uso del plan: ' + errText(error);
      }
      this.governanceLoaded = true;
    }

    this.setSectionMarkup(body, this.governanceMarkup());
    this.bindGovernanceEvents(body);
  }

  private governanceMarkup(): string {
    const errBlock = this.governanceError
      ? `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">${esc(this.governanceError)}</span></div>`
      : '';

    const modes: Array<{ id: GovernanceMode; title: string; desc: string }> = [
      {
        id: 'free',
        title: 'Free-Tier-First',
        desc: 'Prioriza siempre modelos gratuitos; escala a pago solo cuando no hay alternativa viable.',
      },
      {
        id: 'paid',
        title: 'Paid-Tier-First',
        desc: 'Prioriza modelos de pago por calidad; usa el tier gratuito como respaldo.',
      },
      {
        id: 'hybrid',
        title: 'Híbrido',
        desc: 'Balancea coste y calidad según la carga y la salud de cada proveedor.',
      },
      {
        id: 'local',
        title: 'Solo local',
        desc: 'Usa solo los modelos de esta máquina (Ollama): nada sale a la nube, sin claves ni coste, y las tareas corren en secuencia.',
      },
    ];

    const cards = modes
      .map((m) => {
        const active = this.governanceMode === m.id;
        return `
        <button class="card btn-gov-mode ${active ? 'is-active' : ''}" data-mode="${escapeAttribute(m.id)}" title="Aplicar este modo de gobernanza" style="cursor:pointer;text-align:left;flex:1;min-width:200px;${active ? 'border-color:var(--accent)' : ''}">
          <div class="row" style="justify-content:space-between;align-items:center">
            <span class="card__title">${esc(m.title)}</span>
            ${active ? `<span style="color:var(--accent)">${icons.check(16)}</span>` : ''}
          </div>
          <div class="card__subtitle" style="margin-top:6px">${esc(m.desc)}</div>
        </button>`;
      })
      .join('');

    return `
      <div class="col" style="gap:16px">
        ${errBlock}
        <div class="card__subtitle">El modo de gobernanza controla cómo el router elige entre proveedores gratuitos y de pago para cada orden.</div>
        <div class="row" style="gap:12px;flex-wrap:wrap">${cards}</div>
        ${this.budgetMarkup()}
        ${this.usageWeekMarkup()}
      </div>`;
  }

  /**
   * E1.18/F4: presupuesto de pago con corte duro — visible y editable.
   * El gate se cierra ANTES de enviar la llamada; aquí solo se autoriza el
   * cupo. Lo consumido no se edita: es contabilidad, no preferencia.
   */
  private budgetMarkup(): string {
    if (this.budgetError) return `<div class="card settings-error" role="alert">${esc(this.budgetError)}</div>`;
    if (!this.budget) return '';
    const b = this.budget;
    const msgBlock = this.budgetMsg
      ? `<div class="card__subtitle" style="color:${this.budgetMsg.type === 'ok' ? 'var(--success)' : 'var(--danger)'}">${esc(this.budgetMsg.text)}</div>`
      : '';
    return `
      <div class="card col" style="gap:8px" id="budget-card">
        <div class="row" style="justify-content:space-between;align-items:center">
          <span class="card__title">Presupuesto de pago</span>
          <span class="badge ${b.remaining > 0 ? 'badge--success' : 'badge--warning'}">${esc(b.remaining)} restantes</span>
        </div>
        <div class="card__subtitle">
          Una llamada a un modelo no catalogado como gratuito necesita autorización explícita y se descuenta
          al intentarla — el proveedor cobra el intento. Consumidas <b>${esc(b.spent)}</b> de <b>${esc(b.authorized)}</b> llamadas autorizadas.
          0 = corte duro: ninguna llamada de pago sale.
        </div>
        <div class="row" style="gap:8px;align-items:center">
          <label class="card__subtitle" for="inp-budget-authorized" style="margin:0">Autorizar</label>
          <input class="input" id="inp-budget-authorized" type="number" min="0" step="1" value="${escapeAttribute(b.authorized)}" style="width:110px" />
          <span class="card__subtitle">llamadas de pago</span>
          <button class="btn" id="btn-budget-save" title="Escribe el cupo en el ajuste del motor; el gate lo lee antes de cada llamada">Guardar</button>
        </div>
        ${msgBlock}
      </div>`;
  }

  /**
   * E1.16/F4: medidor de uso del plan — ventana móvil de 7 días con el aviso
   * de rate-limit (claves que no están 'active' delante del usuario).
   */
  private usageWeekMarkup(): string {
    if (this.usageWeekError) return `<div class="card settings-error" role="alert">${esc(this.usageWeekError)}</div>`;
    if (!this.usageWeek) return '';
    const u = this.usageWeek;
    const fmtTok = (n: number) => (n >= 1_000_000 ? `${(n / 1_000_000).toFixed(1)}M` : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : `${n}`);
    const top = u.by_model
      .slice(0, 5)
      .map((m) => `<div class="row" style="justify-content:space-between"><span class="card__subtitle">${esc(m.provider)}/${esc(m.model)}</span><span class="card__subtitle">${fmtTok(m.total)} tok</span></div>`)
      .join('');
    const limited = u.limited_keys
      .map(
        (k) =>
          `<div class="row" style="justify-content:space-between"><span class="card__subtitle" style="color:var(--warning)">${esc(k.provider)} · ${esc(k.label)} — ${esc(k.status)} (cuota ${esc(k.quota_used)}${k.quota_limit > 0 ? `/${esc(k.quota_limit)}` : ''})</span></div>`,
      )
      .join('');
    const warn = u.limited_keys.length
      ? `<div class="card__subtitle" style="color:var(--warning);font-weight:600">Aviso de rate-limit: ${u.limited_keys.length} clave${u.limited_keys.length === 1 ? '' : 's'} fuera de servicio o enfriando.</div>${limited}`
      : `<div class="card__subtitle" style="color:var(--success)">Todas las claves activas — sin rate-limit vigente.</div>`;
    return `
      <div class="card col" style="gap:8px" id="usage-week-card">
        <div class="row" style="justify-content:space-between;align-items:center">
          <span class="card__title">Uso del plan — últimos 7 días</span>
          <span class="badge badge--info">${esc(u.calls)} llamadas</span>
        </div>
        <div class="card__subtitle">
          ${fmtTok(u.total)} tokens (${fmtTok(u.prompt)} entrada · ${fmtTok(u.completion)} salida).
          Los límites por clave están en la sección Proveedores; aquí va el agregado.
        </div>
        ${top}
        ${warn}
      </div>`;
  }

  private bindGovernanceEvents(body: HTMLElement): void {
    body.querySelector<HTMLElement>('#btn-budget-save')?.addEventListener('click', async () => {
      if (!this.core) return;
      const inp = body.querySelector<HTMLInputElement>('#inp-budget-authorized');
      const n = parseInt(inp?.value ?? '', 10);
      if (isNaN(n) || n < 0) {
        this.budgetMsg = { type: 'error', text: 'Las llamadas autorizadas deben ser un número mayor o igual a 0.' };
        this.setSectionMarkup(body, this.governanceMarkup());
        this.bindGovernanceEvents(body);
        return;
      }
      try {
        await this.core.setBudgetAuthorized(n);
        this.budget = await this.core.getBudget();
        document.dispatchEvent(new CustomEvent('devagents:budget-changed'));
        this.budgetMsg = { type: 'ok', text: `Presupuesto actualizado: ${n} llamadas de pago autorizadas.` };
      } catch (e) {
        this.budgetMsg = { type: 'error', text: errText(e) };
      }
      this.setSectionMarkup(body, this.governanceMarkup());
      this.bindGovernanceEvents(body);
    });
    body.querySelectorAll<HTMLElement>('.btn-gov-mode').forEach((el) => {
      el.addEventListener('click', async () => {
        if (!this.core) return;
        const mode = el.dataset.mode as GovernanceMode;
        try {
          const res = await this.core.setGovernance(mode);
          this.governanceMode = res.mode;
          this.governanceError = null;
        } catch (e) {
          this.governanceError = errText(e);
        }
        this.setSectionMarkup(body, this.governanceMarkup());
        this.bindGovernanceEvents(body);
      });
    });
  }

  // ---------------------------------------------------------------- Skills

  /**
   * Skills descubiertas por el motor en las carpetas enlazadas.
   *
   * `da_skills_discover_json` llevaba exportada desde el principio y nadie la
   * llamaba. Escanea cada montaje activo buscando `SKILL.md`, así que sin
   * montajes la lista sale vacía: eso NO es un error y el estado vacío lo dice,
   * porque una tabla en blanco sin explicación parece una avería.
   */
  private async renderSkillsSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;
    this.setSectionMarkup(body, this.loadingBlock('Buscando skills en las carpetas enlazadas…'));

    let rows: Array<Record<string, unknown>> = [];
    let mounts: Array<Record<string, unknown>> = [];
    let error = '';
    try {
      [rows, mounts] = await Promise.all([this.core.skills(), this.core.mounts()]);
    } catch (e) {
      error = errText(e);
    }

    const cards = rows
      .map((s) => {
        const name = String(s.name ?? s.id ?? 'sin nombre');
        const desc = String(s.description ?? s.summary ?? '');
        const path = String(s.path ?? s.source ?? '');
        return `<div class="card">
          <div class="row" style="justify-content:space-between;gap:12px;align-items:center">
            <span class="card__title">${esc(name)}</span>
            <span class="badge badge--accent">skill</span>
          </div>
          ${desc ? `<div class="card__subtitle" style="margin-top:6px">${esc(desc)}</div>` : ''}
          ${path ? `<div class="subtle mono truncate" style="font-size:11px;margin-top:6px">${esc(path)}</div>` : ''}
        </div>`;
      })
      .join('');

    this.setSectionMarkup(body, `
      <div class="col" style="gap:16px">
        ${
          error
            ? `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">${esc(error)}</span></div>`
            : ''
        }
        <div class="card__subtitle">
          El agente descubre skills recorriendo las carpetas que hayas enlazado como montajes.
          Cada carpeta con un <code>SKILL.md</code> se convierte en una capacidad que el selector
          de herramientas puede elegir según la tarea.
        </div>

        <!-- Montajes. Viven aquí y no en una sección aparte porque son la
             MISMA cosa vista de otro lado: sin montajes no hay skills, y hasta
             ahora la interfaz solo sabía leerlos. addMount y removeMount
             existían en core_api.ts sin un solo llamador. -->
        <div class="card">
          <div class="card__title">Carpetas enlazadas</div>
          <div class="card__subtitle">
            Rutas que el agente puede leer además del workspace. El sandbox del motor
            sigue bloqueando todo lo que quede fuera de esta lista.
          </div>
          <div class="row" style="gap:8px;margin-top:10px">
            <input class="input mono" id="mount-input" placeholder="C:\\ruta\\a\\la\\carpeta" />
            <button class="btn" id="mount-browse" title="Elegir la carpeta con el diálogo del sistema">${icons.folder(14)}<span>Examinar</span></button>
            <button class="btn" id="mount-add" title="Enlazar una carpeta externa como espacio de trabajo">${icons.plus(14)}<span>Enlazar</span></button>
          </div>
          <div class="col" style="gap:6px;margin-top:10px">
            ${
              mounts.length
                ? mounts
                    .map((mt) => {
                      const p = String(mt.path ?? mt.root ?? mt);
                      return `<div class="list-item" style="cursor:default">
                        <span class="list-item__icon">${icons.folder(14)}</span>
                        <span class="list-item__label mono truncate">${esc(p)}</span>
                        <button class="icon-btn btn-mount-rm" data-path="${escapeAttribute(p)}" title="Desenlazar">${icons.trash(14)}</button>
                      </div>`;
                    })
                    .join('')
                : '<div class="empty-state"><span>Ninguna carpeta enlazada todavía.</span></div>'
            }
          </div>
          <div id="mount-msg" class="subtle" style="margin-top:8px"></div>
        </div>
        ${
          rows.length
            ? `<div class="col" style="gap:10px">${cards}</div>`
            : `<div class="empty-state">
                 ${icons.layers(22)}
                 <span class="empty-state__title">Ninguna skill descubierta</span>
                 <span>No hay carpetas enlazadas, o ninguna contiene un SKILL.md.
                 Enlaza carpetas con <span class="mono">devagents mount add &lt;ruta&gt;</span>.</span>
               </div>`
        }
      </div>`);

    const msg = body.querySelector<HTMLElement>('#mount-msg');
    const fail = (e: unknown): void => {
      if (msg) {
        msg.textContent = errText(e);
        msg.style.color = 'var(--danger)';
      }
    };

    // Escribir la ruta a mano sigue valiendo, pero el camino normal es el
    // diálogo del sistema: menos erratas y ninguna duda sobre las barras
    // invertidas de Windows.
    body.querySelector('#mount-browse')?.addEventListener('click', () => {
      if (!this.core) return;
      void this.core
        .pickFolder('Elige la carpeta que el agente podrá leer')
        .then((picked) => {
          if (picked.cancelled || !picked.path) return;
          const input = body.querySelector<HTMLInputElement>('#mount-input');
          if (input) input.value = picked.path;
        })
        .catch(fail);
    });

    body.querySelector('#mount-add')?.addEventListener('click', () => {
      const input = body.querySelector<HTMLInputElement>('#mount-input');
      const path = input?.value.trim();
      if (!path || !this.core) return;
      void this.core
        .addMountPath(path)
        .then(() => this.renderSkillsSection())
        .catch(fail);
    });

    body.querySelectorAll<HTMLElement>('.btn-mount-rm').forEach((el) => {
      el.addEventListener('click', () => {
        if (!this.core) return;
        void this.core
          .removeMountPath(el.dataset.path || '')
          .then(() => this.renderSkillsSection())
          .catch(fail);
      });
    });
  }

  // --------------------------------------------------------------- Plugins

  /**
   * Plugins nativos instalados.
   *
   * `plugin_loader.zig` lleva tiempo verificando la ABI, anclando el SHA-256
   * del DLL en `catalog.db` y cargando la biblioteca de verdad. No había una
   * sola función `da_plugin_*`, así que todo eso era código muerto con tests
   * propios.
   *
   * Se listan TAMBIÉN los plugins que no cargan, con el motivo. Un plugin que
   * desaparece de la lista sin explicación es lo peor que le puede pasar a
   * quien está intentando instalarlo.
   */
  private async renderPluginsSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;
    this.setSectionMarkup(body, this.loadingBlock('Consultando plugins instalados…'));

    let items: PluginItem[] = [];
    let dir = '';
    try {
      [items, dir] = await Promise.all([
        this.core.plugins(),
        this.core.pluginsDir().then((r) => r.path || ''),
      ]);
    } catch (e) {
      this.setSectionMarkup(body, `<div class="empty-state" style="color:var(--danger)">${esc(errText(e))}</div>`);
      return;
    }

    const tarjetas = items
      .map((p) => {
        const caps = (p.capabilities || [])
          .map((c) => `<span class="pill" title="${escapeAttribute(c.description)}">${esc(c.kind)}: ${esc(c.name)}</span>`)
          .join(' ');
        return `
          <div class="card col" style="gap:6px;padding:10px 12px">
            <div class="row" style="justify-content:space-between;align-items:center;gap:8px">
              <div class="row" style="gap:8px;align-items:center;min-width:0">
                <span class="mono truncate" style="font-weight:600">${esc(p.name)}</span>
                ${p.version ? `<span class="subtle" style="font-size:11px">v${esc(p.version)}</span>` : ''}
                <span class="pill ${p.trusted ? 'pill--online' : 'pill--offline'}">
                  <span class="pill__dot"></span>${p.trusted ? 'De confianza' : 'Sin cargar'}
                </span>
              </div>
              <div class="row" style="gap:6px">
                ${
                  p.trusted
                    ? `<button class="btn btn-plugin-untrust" data-name="${escapeAttribute(p.name)}" title="Retirar la confianza de este plugin">Retirar confianza</button>`
                    : `<button class="btn btn-plugin-trust" data-folder="${escapeAttribute(p.folder)}" title="Anclar esta carpeta como plugin de confianza y cargarlo">Anclar y cargar</button>`
                }
              </div>
            </div>
            ${caps ? `<div class="row" style="flex-wrap:wrap;gap:4px">${caps}</div>` : ''}
            ${
              p.error
                ? `<span class="subtle mono" style="font-size:11px;color:var(--danger)">${esc(p.error)}</span>`
                : ''
            }
            <span class="subtle mono" style="font-size:11px">${esc(p.folder)}${p.dllName ? ' · ' + esc(p.dllName) : ''}</span>
          </div>`;
      })
      .join('');

    this.setSectionMarkup(body, `
      <div class="col" style="gap:12px">
        <div class="card col" style="gap:6px;padding:12px">
          <h3 class="card__title">Cómo se instala un plugin</h3>
          <span class="subtle" style="font-size:12px">
            Copia su carpeta (con <span class="mono">plugin.json</span> y su DLL al lado) dentro de
            <span class="mono">${esc(dir)}</span>, vuelve aquí y pulsa <strong>Anclar y cargar</strong>.
          </span>
          <span class="settings-callout">
            Al anclarlo se guarda el SHA-256 del DLL. Si el archivo cambia después, deja de cargarse
            hasta que vuelvas a anclarlo a propósito: un plugin es código nativo dentro de este proceso.
          </span>
          <div class="row" style="gap:6px;margin-top:4px">
            <button class="btn" id="plugins-refresh" title="Recargar la lista de plugins">Actualizar</button>
          </div>
        </div>
        <div id="plugin-msg" class="subtle" style="font-size:11px"></div>
        ${
          items.length
            ? `<div class="col" style="gap:8px">${tarjetas}</div>`
            : `<div class="empty-state">
                 <span class="empty-state__title">Ningún plugin instalado</span>
                 <span>La carpeta de plugins está vacía.</span>
               </div>`
        }
      </div>`);

    const msg = body.querySelector<HTMLElement>('#plugin-msg');
    const fail = (e: unknown): void => {
      if (msg) {
        msg.textContent = errText(e);
        msg.style.color = 'var(--danger)';
      }
    };

    body.querySelector('#plugins-refresh')?.addEventListener('click', () => {
      void this.renderPluginsSection();
    });
    body.querySelectorAll<HTMLElement>('.btn-plugin-trust').forEach((el) => {
      el.addEventListener('click', () => {
        void this.core
          ?.trustPlugin(el.dataset.folder || '')
          .then(() => this.renderPluginsSection())
          .catch(fail);
      });
    });
    body.querySelectorAll<HTMLElement>('.btn-plugin-untrust').forEach((el) => {
      el.addEventListener('click', () => {
        void this.core
          ?.untrustPlugin(el.dataset.name || '')
          .then(() => this.renderPluginsSection())
          .catch(fail);
      });
    });
  }

  // --------------------------------------------------------------- Memoria

  /**
   * Lo que la memoria del agente recuerda de este proyecto.
   *
   * El motor usa Engram si `ENGRAM_BIN` apunta a un binario válido, y si no un
   * respaldo local. Hasta ahora era una caja negra: se guardaba contexto y
   * lecciones y no había forma de verlos. El JSON no tiene forma fija (depende
   * del backend), así que se pintan las claves conocidas y el resto en crudo,
   * antes que inventar una estructura que el backend no garantiza.
   */
  private async renderMemorySection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;
    this.setSectionMarkup(body, this.loadingBlock('Consultando la memoria del agente…'));

    let ctx: Record<string, unknown> = {};
    let error = '';
    try {
      ctx = (await this.core.memoryContext('default')) || {};
    } catch (e) {
      error = errText(e);
    }

    const list = (key: string, title: string): string => {
      const arr = Array.isArray(ctx[key]) ? (ctx[key] as unknown[]) : [];
      if (!arr.length) return '';
      return `<div class="card">
        <div class="card__title">${esc(title)} · ${arr.length}</div>
        <div class="col" style="gap:6px;margin-top:10px">
          ${arr
            .slice(0, 50)
            .map((it) => {
              const text =
                typeof it === 'string' ? it : String((it as Record<string, unknown>)?.text ?? JSON.stringify(it));
              return `<div class="list-item" style="cursor:default"><span class="list-item__label">${esc(text)}</span></div>`;
            })
            .join('')}
        </div>
      </div>`;
    };

    const known = list('sessions', 'Sesiones recordadas') + list('findings', 'Hallazgos') + list('lessons', 'Lecciones');

    // Engram devuelve el grueso del contexto en `result`, como un bloque de
    // markdown, no en listas. La primera versión de este panel solo miraba
    // sessions/findings/lessons y habría anunciado "memoria vacía" teniendo
    // 875 observaciones guardadas.
    const resultText = typeof ctx.result === 'string' ? ctx.result : '';
    const note = typeof ctx.note === 'string' ? ctx.note : '';
    const projectPath = typeof ctx.project_path === 'string' ? ctx.project_path : '';
    const projectName = typeof ctx.project === 'string' ? ctx.project : 'default';

    const header = `<div class="card">
      <div class="row" style="gap:24px;flex-wrap:wrap">
        <div class="col" style="gap:2px"><span class="section-label">Proyecto</span><span>${esc(projectName)}</span></div>
        ${
          projectPath
            ? `<div class="col" style="gap:2px"><span class="section-label">Ruta</span><span class="mono truncate" style="max-width:420px;display:block">${esc(projectPath)}</span></div>`
            : ''
        }
        <div class="col" style="gap:2px"><span class="section-label">Origen</span><span>${esc(String(ctx.project_source ?? '—'))}</span></div>
      </div>
    </div>`;

    this.setSectionMarkup(body, `
      <div class="col" style="gap:16px">
        ${
          error
            ? `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">${esc(error)}</span></div>`
            : ''
        }
        <div class="card__subtitle">
          Contexto que el agente conserva entre sesiones de este proyecto. Lo alimenta Engram
          si está disponible (variable <span class="mono">ENGRAM_BIN</span>), y si no un almacén local.
        </div>
        ${error ? '' : header}
        ${known}
        ${
          resultText
            ? `<div class="card">
                 <div class="card__title">Lo que recuerda</div>
                 <div class="code-surface scroll-y" style="margin-top:10px;max-height:420px;padding:12px;
                      white-space:pre-wrap;overflow-wrap:anywhere;font-size:11px;line-height:1.6">${esc(resultText)}</div>
               </div>`
            : ''
        }
        ${
          !known && !resultText && !error
            ? `<div class="empty-state">
                 ${icons.layers(22)}
                 <span class="empty-state__title">La memoria está vacía</span>
                 <span>${esc(note || 'Aún no hay contexto guardado para este proyecto.')}</span>
               </div>`
            : ''
        }
      </div>`);
  }

  // ----------------------------------------------------------------- Hooks

  /**
   * Igual que los permisos, el motor no expone getter de hooks: se guarda un
   * espejo en localStorage y se reaplica al abrir la sección, para que el motor
   * arranque con lo último que dejó el usuario.
   */
  /**
 * T7 (f): «Cuentas de CLI». Cada cuenta vive en su carpeta dentro
   * de los datos de DevAgents (CODEX_HOME / CLAUDE_CONFIG_DIR). «Iniciar
   * sesión» abre la terminal integrada con ese entorno y el comando de la CLI:
   * el usuario escribe sus credenciales en la CLI y DevAgents no las ve. El
   * login del sistema (carpeta por defecto de la CLI) no se toca.
   */
  private async renderAccountsSection(message = '', isError = false): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;
    this.setSectionMarkup(body, this.loadingBlock('Cargando las cuentas de las CLIs…'));
    let state: CliAccountsState;
    try {
      state = await this.core.getCliAccounts();
    } catch (e) {
      this.setSectionMarkup(body, `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">No se pudieron leer las cuentas: ${esc(errText(e))}</span></div>`);
      return;
    }
    const cards = state.clis.map((c) => {
      const rows = c.accounts.map((acc) => `
        <div class="row" style="gap:8px;align-items:center;margin-top:6px">
          <span style="flex:1"><strong>${esc(acc.label)}</strong> <code class="mono">${esc(acc.dir)}</code></span>
          <button class="btn btn--sm acc-login" type="button" data-command="${escapeAttribute(acc.loginCommand)}" title="Abre la terminal integrada con ${escapeAttribute(c.envVar)} de esta cuenta">Iniciar sesión</button>
          <button class="btn btn--sm acc-remove" type="button" data-id="${escapeAttribute(acc.id)}" title="Quitar la cuenta y su carpeta">Quitar</button>
        </div>`).join('');
      const options = [`<option value="" ${c.selected ? '' : 'selected'}>Login del sistema (sin rotación)</option>`]
        .concat(c.accounts.map((acc) => `<option value="${escapeAttribute(acc.id)}" ${c.selected === acc.id ? 'selected' : ''}>${esc(acc.label)}</option>`)).join('');
      return `
        <div class="card" data-cli="${escapeAttribute(c.cli)}">
          <div class="card__title">${esc(c.display)}</div>
          <div class="card__subtitle">Cada cuenta usa su propia carpeta (<code>${esc(c.envVar)}</code>). Si la cuenta agota su cuota, la orden sigue con la siguiente y lo dice en el hilo.</div>
          ${rows || '<div class="card__subtitle" style="margin-top:6px">Sin cuentas: se usa el login del sistema.</div>'}
          <div class="field" style="margin-top:10px">
            <span class="field__label">Cuenta con la que empiezan las órdenes</span>
            <select class="acc-select" id="acc-select-${escapeAttribute(c.cli)}" data-cli="${escapeAttribute(c.cli)}">${options}</select>
          </div>
          <div class="row" style="gap:8px;margin-top:10px">
            <input class="acc-label" id="acc-label-${escapeAttribute(c.cli)}" placeholder="Nombre de la cuenta (p. ej. Trabajo)" maxlength="40" aria-label="Nombre de la nueva cuenta de ${escapeAttribute(c.display)}" />
            <button class="btn acc-add" type="button" data-cli="${escapeAttribute(c.cli)}">Añadir cuenta</button>
          </div>
        </div>`;
    }).join('');
    const unsupported = state.unsupported.map((u) => `<li><strong>${esc(u.display)}</strong>: ${esc(u.why)}</li>`).join('');
    this.setSectionMarkup(body, `
      <div class="col" style="gap:16px">
        ${cards}
        <div class="card"><div class="card__title">No disponibles</div><ul class="card__subtitle">${unsupported}</ul></div>
        <div id="acc-msg" style="${isError ? 'color:var(--danger)' : ''}">${esc(message)}</div>
        ${state.notice ? `<div id="acc-notice" role="alert" style="color:var(--warning, var(--danger))">${esc(state.notice)}</div>` : ''}
      </div>`);
    const done = (p: Promise<unknown>, okText: string): Promise<void> => p
      .then(() => this.renderAccountsSection(okText))
      .catch((e) => this.renderAccountsSection(errText(e), true));
    body.querySelectorAll<HTMLButtonElement>('.acc-add').forEach((btn) => btn.addEventListener('click', () => {
      const cli = btn.dataset.cli ?? '';
      const label = body.querySelector<HTMLInputElement>(`#acc-label-${cli}`)?.value.trim() ?? '';
      if (!this.core || !label) return;
      void done(this.core.addCliAccount(cli, label), 'Cuenta creada. Pulsa «Iniciar sesión» para entrar con ella.');
    }));
    body.querySelectorAll<HTMLButtonElement>('.acc-remove').forEach((btn) => btn.addEventListener('click', () => {
      if (!this.core || !confirm('¿Quitar la cuenta y borrar su carpeta? Tendrás que volver a iniciar sesión si la añades otra vez.')) return;
      void done(this.core.removeCliAccount(btn.dataset.id ?? ''), 'Cuenta quitada.');
    }));
    body.querySelectorAll<HTMLSelectElement>('.acc-select').forEach((sel) => sel.addEventListener('change', () => {
      if (!this.core) return;
      void done(this.core.selectCliAccount(sel.dataset.cli ?? '', sel.value), 'Cuenta para las órdenes guardada.');
    }));
    body.querySelectorAll<HTMLButtonElement>('.acc-login').forEach((btn) => btn.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('devagents:run-command', { detail: btn.dataset.command ?? '' }));
    }));
  }

  /**
 * T7 (e): «Reglas del proyecto». Por defecto, las de código
   * limpio de DevAgents; el usuario puede escribir las suyas. Se guardan en el
   * motor por carpeta de proyecto (no en la página) y llegan a Directo,
   * Orquestado, Colmena, delegación y a las CLIs externas.
   */
  private async renderRulesSection(message = '', isError = false): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;
    this.setSectionMarkup(body, this.loadingBlock('Cargando las reglas del proyecto…'));
    let info: ProjectRules;
    try {
      info = await this.core.getProjectRules();
    } catch (e) {
      this.setSectionMarkup(body, `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">No se pudieron leer las reglas del proyecto: ${esc(errText(e))}</span></div>`);
      return;
    }
    const docs = info.projectDocs.length
      ? `Este proyecto trae ${info.projectDocs.map((d) => `<code>${esc(d)}</code>`).join(' y ')}: sus instrucciones mandan sobre estas reglas cuando choquen.`
      : 'Si el proyecto trae <code>AGENTS.md</code> o <code>CLAUDE.md</code>, sus instrucciones mandan sobre estas reglas cuando choquen (como hace Codex con AGENTS.md).';
    this.setSectionMarkup(body, `
      <div class="col" style="gap:16px">
        <div class="card">
          <div class="card__title">${info.custom ? 'Reglas propias de este proyecto' : 'Reglas de DevAgents (código limpio)'}</div>
          <div class="card__subtitle">Carpeta: <code>${esc(info.projectRoot)}</code>. Llegan al prompt de Directo, Orquestado, Colmena, las subtareas delegadas y el encargo a Claude Code, Codex, Gemini CLI u OpenCode.</div>
          <div class="card__subtitle" style="margin-top:6px">${docs}</div>
          <div class="field" style="margin-top:12px">
            <span class="field__label">Reglas</span>
            <span class="field__hint">Una por línea. Máximo ${Math.floor(info.maxBytes / 1024)} KiB. Vacío vuelve a las de DevAgents.</span>
            <textarea id="rules-text" class="mono" rows="14" spellcheck="false">${esc(info.rules)}</textarea>
          </div>
          <div class="row" style="gap:8px;margin-top:10px">
            <button class="btn btn--primary" id="rules-save" type="button">Guardar</button>
            <button class="btn" id="rules-reset" type="button" ${info.custom ? '' : 'disabled'}>Volver a las de DevAgents</button>
          </div>
          <div id="rules-msg" style="margin-top:8px;${isError ? 'color:var(--danger)' : ''}">${esc(message)}</div>
        </div>
      </div>`);
    const textarea = body.querySelector<HTMLTextAreaElement>('#rules-text');
    body.querySelector<HTMLButtonElement>('#rules-save')?.addEventListener('click', () => {
      const text = textarea?.value ?? '';
      if (!this.core) return;
      this.core.setProjectRules(text)
        .then((next) => this.renderRulesSection(next.custom ? 'Reglas guardadas para este proyecto.' : 'Se usan las reglas de DevAgents.'))
        .catch((e) => this.renderRulesSection('No se guardaron: ' + errText(e), true));
    });
    body.querySelector<HTMLButtonElement>('#rules-reset')?.addEventListener('click', () => {
      if (!this.core) return;
      this.core.resetProjectRules()
        .then(() => this.renderRulesSection('Se usan las reglas de DevAgents.'))
        .catch((e) => this.renderRulesSection('No se restauraron: ' + errText(e), true));
    });
  }

  private renderHooksSection(): void {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body) return;

    const cfg = loadHooksFromStorage();
    const field = (id: string, label: string, hint: string, value: string, ph: string): string => `
      <div class="field" style="margin-top:12px">
        <span class="field__label">${esc(label)}</span>
        <span class="card__subtitle" style="margin-bottom:6px">${hint}</span>
        <input class="input mono" id="${id}" value="${escapeAttribute(value)}" placeholder="${escapeAttribute(ph)}" />
      </div>`;

    this.setSectionMarkup(body, `
      <div class="col" style="gap:16px">
        <div class="card__subtitle">
          Ejecuta un comando del sistema antes o después de cada acción del agente.
          Un hook <strong>previo</strong> que termine con código distinto de cero
          <strong>bloquea</strong> la acción; los posteriores solo informan.
          Marcadores disponibles: <code>{path}</code>, <code>{exe}</code>, <code>{cwd}</code>.
        </div>

        <div class="card">
          <label class="row" style="gap:8px;align-items:center;cursor:pointer">
            <input type="checkbox" id="hooks-enabled" ${cfg.enabled ? 'checked' : ''} />
            <span class="card__title" style="margin:0">Activar hooks</span>
          </label>
          <div class="card__subtitle" style="margin-top:6px">
            Con esto apagado no se lanza ningún comando, aunque haya líneas escritas abajo.
          </div>
        </div>

        <div class="card">
          <div class="card__title">Al escribir archivos</div>
          <div class="card__subtitle">Se disparan en cada archivo que el agente materializa.</div>
          ${field('hook-pre-edit', 'Antes de escribir', 'Para bloquear rutas prohibidas. Devuelve código ≠ 0 y la escritura no ocurre.', cfg.preEdit, 'cmd /c if not "%1"=="" exit 0')}
          ${field('hook-post-edit', 'Después de escribir', 'Para formatear o lintar. El archivo ya está cerrado cuando se lanza.', cfg.postEdit, 'zig fmt {path}')}
        </div>

        <div class="card">
          <div class="card__title">Al ejecutar comandos</div>
          <div class="card__subtitle">Se disparan alrededor de cada ejecución gobernada.</div>
          ${field('hook-pre-cmd', 'Antes de ejecutar', 'Recibe {exe} y {cwd}. Devuelve código ≠ 0 para vetar el comando.', cfg.preCommand, '')}
          ${field('hook-post-cmd', 'Después de ejecutar', '', cfg.postCommand, '')}
        </div>

        <div class="row" style="gap:8px;align-items:center">
          <button class="btn btn--primary" id="hooks-save" title="Guardar la configuración de hooks">Guardar hooks</button>
          <span id="hooks-msg" class="subtle"></span>
        </div>
      </div>`);

    body.querySelector('#hooks-save')?.addEventListener('click', () => {
      const val = (id: string): string =>
        body.querySelector<HTMLInputElement>(`#${id}`)?.value.trim() || '';
      const next = {
        enabled: !!body.querySelector<HTMLInputElement>('#hooks-enabled')?.checked,
        preEdit: val('hook-pre-edit'),
        postEdit: val('hook-post-edit'),
        preCommand: val('hook-pre-cmd'),
        postCommand: val('hook-post-cmd'),
        timeoutMs: 15000,
      };
      const msg = body.querySelector<HTMLElement>('#hooks-msg');
      void this.core
        ?.setHooks(next)
        .then(() => {
          window.localStorage.setItem(HOOKS_STORAGE_KEY, JSON.stringify(next));
          if (msg) {
            msg.textContent = 'Hooks aplicados.';
            msg.style.color = 'var(--success)';
          }
        })
        .catch((e) => {
          if (msg) {
            msg.textContent = errText(e);
            msg.style.color = 'var(--danger)';
          }
        });
    });
  }

  // --------------------------------------------------------------- Permisos

  private async renderPermissionsSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;

    if (!this.permissionsLoaded) {
      this.setSectionMarkup(body, this.loadingBlock('Cargando permisos…'));
      // 10-nov: se LEE lo que tiene el motor (que ya lo guarda entre
      // arranques). Antes se reaplicaba el espejo local al abrir la página, lo
      // que pedía la autorización del host y dejaba «Cargando permisos…»
      // colgado mientras el diálogo esperaba. Con un motor viejo sin lectura,
      // se muestra el espejo local sin tocar nada.
      this.permissions = loadPermissionsFromStorage();
      try {
        const live = typeof this.core.getPermissions === 'function' ? await this.core.getPermissions() : null;
        if (live && typeof live.mode === 'string') {
          this.permissions = { mode: live.mode, allow: Array.isArray(live.allow) ? live.allow : [], deny: Array.isArray(live.deny) ? live.deny : [] };
          try { window.localStorage.setItem('devagents.permissions', JSON.stringify(this.permissions)); } catch { /* espejo opcional */ }
        }
        this.permissionsError = null;
      } catch (e) {
        this.permissionsError = errText(e);
      }
      this.permissionsLoaded = true;
    }

    this.setSectionMarkup(body, this.permissionsMarkup());
    this.bindPermissionsEvents(body);
  }

  private permissionsMarkup(): string {
    const errBlock = this.permissionsError
      ? `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">${esc(this.permissionsError)}</span></div>`
      : '';

    const modes: Array<{ id: PermissionMode; title: string; desc: string }> = [
      { id: 'normal', title: 'Normal', desc: 'Pide aprobación para cada acción con efectos.' },
      {
        id: 'accept_edits',
        title: 'Aceptar ediciones',
        desc: 'Acepta ediciones de archivo automáticamente; sigue preguntando por comandos.',
      },
      { id: 'bypass', title: 'Bypass', desc: 'No pregunta nada. Úsalo solo en entornos desechables.' },
      { id: 'autonomous', title: 'Autónomo', desc: 'Modo desatendido para tareas largas sin supervisión.' },
    ];

    const cards = modes
      .map((m) => {
        const active = this.permissions.mode === m.id;
        const warning =
          m.id === 'bypass'
            ? `<div class="row" style="gap:6px;margin-top:8px;color:var(--warning)">${icons.alert(13)}<span style="font-size:11px">Sin red de seguridad: el agente ejecuta cualquier acción sin confirmación.</span></div>`
            : '';
        return `
        <button class="card btn-perm-mode ${active ? 'is-active' : ''}" data-mode="${escapeAttribute(m.id)}" title="Aplicar este modo de permisos" style="cursor:pointer;text-align:left;flex:1;min-width:220px;${active ? 'border-color:var(--accent)' : ''}">
          <div class="row" style="justify-content:space-between;align-items:center">
            <span class="card__title">${esc(m.title)}</span>
            ${active ? `<span style="color:var(--accent)">${icons.check(16)}</span>` : ''}
          </div>
          <div class="card__subtitle" style="margin-top:6px">${esc(m.desc)}</div>
          ${warning}
        </button>`;
      })
      .join('');

    const listMarkup = (items: string[], kind: 'allow' | 'deny'): string =>
      items.length
        ? items
            .map(
              (v, i) => `
            <div class="list-item" style="cursor:default">
              <span class="list-item__icon">${icons.terminal(14)}</span>
              <span class="list-item__label mono">${esc(v)}</span>
              <button class="icon-btn btn-perm-remove" data-kind="${kind}" data-idx="${i}" title="Quitar prefijo">${icons.trash(14)}</button>
            </div>`
            )
            .join('')
        : `<div class="empty-state"><span>Sin prefijos ${kind === 'allow' ? 'permitidos' : 'denegados'} todavía.</span></div>`;

    // El aviso de bypass ya NO se pinta aquí: es una ventana emergente
    // (design/modal.ts) que se abre desde bindPermissionsEvents. En línea se
    // podía seguir usando el resto de la sección con la advertencia a medio
    // leer, y en una ventana pequeña quedaba por debajo del pliegue.

    return `
      <div class="col" style="gap:16px">
        ${errBlock}
        <div class="card__subtitle">
          Controla qué puede hacer el agente sin preguntar. Se guarda solo en este equipo y se mantiene
          entre arranques. Restringir nunca pregunta; ampliar lo confirma DevAgents en una ventana propia.
          Bypass y Autónomo se confirman una sola vez y quedan recordados en este equipo.
        </div>
        <div class="perm-mode-grid">${cards}</div>
        <div class="row" style="gap:8px;align-items:center;flex-wrap:wrap">
          <button class="btn" id="perm-forget-elevated" title="DevAgents olvida que ya confirmaste Bypass y Autónomo">Volver a pedir confirmación para Auto y Omitir</button>
          ${this.permissionsNote ? `<span class="card__subtitle" id="perm-forget-note">${esc(this.permissionsNote)}</span>` : ''}
        </div>

        <div class="card">
          <div class="card__title">Prefijos permitidos</div>
          <div class="card__subtitle">Comandos que empiezan por estos prefijos se ejecutan sin pedir aprobación.</div>
          <div class="row" style="gap:8px;margin-top:10px">
            <input class="input" id="perm-allow-input" placeholder="p. ej. git status" />
            <button class="btn" id="perm-allow-add" title="Añadir una regla que permite la acción">${icons.plus(14)}<span>Añadir</span></button>
          </div>
          <div class="col" style="gap:6px;margin-top:10px">${listMarkup(this.permissions.allow, 'allow')}</div>
        </div>

        <div class="card">
          <div class="card__title">Prefijos denegados</div>
          <div class="card__subtitle">Comandos que empiezan por estos prefijos se bloquean siempre, incluso en modo bypass.</div>
          <div class="row" style="gap:8px;margin-top:10px">
            <input class="input" id="perm-deny-input" placeholder="p. ej. rm -rf" />
            <button class="btn" id="perm-deny-add" title="Añadir una regla que deniega la acción">${icons.plus(14)}<span>Añadir</span></button>
          </div>
          <div class="col" style="gap:6px;margin-top:10px">${listMarkup(this.permissions.deny, 'deny')}</div>
        </div>
      </div>`;
  }

  private bindPermissionsEvents(body: HTMLElement): void {
    body.querySelectorAll<HTMLElement>('.btn-perm-mode').forEach((el) => {
      el.addEventListener('click', () => {
        const mode = el.dataset.mode as PermissionMode;
        // sin aviso de la página delante. Bypass y Autónomo los
        // confirma UNA vez DevAgents en su ventana propia (lo recuerda el
        // host en este equipo, no la página); antes se pedía dos veces.
        this.permissions = { ...this.permissions, mode };
        void this.applyPermissions(body);
      });
    });

    body.querySelector('#perm-forget-elevated')?.addEventListener('click', () => {
      void this.forgetElevatedPermissions(body);
    });

    const allowInput = body.querySelector<HTMLInputElement>('#perm-allow-input');
    body.querySelector('#perm-allow-add')?.addEventListener('click', () => {
      const v = (allowInput?.value || '').trim();
      if (!v) return;
      this.permissions = { ...this.permissions, allow: [...this.permissions.allow, v] };
      void this.applyPermissions(body);
    });
    allowInput?.addEventListener('keydown', (ev) => {
      if ((ev as KeyboardEvent).key === 'Enter') {
        ev.preventDefault();
        body.querySelector<HTMLButtonElement>('#perm-allow-add')?.click();
      }
    });

    const denyInput = body.querySelector<HTMLInputElement>('#perm-deny-input');
    body.querySelector('#perm-deny-add')?.addEventListener('click', () => {
      const v = (denyInput?.value || '').trim();
      if (!v) return;
      this.permissions = { ...this.permissions, deny: [...this.permissions.deny, v] };
      void this.applyPermissions(body);
    });
    denyInput?.addEventListener('keydown', (ev) => {
      if ((ev as KeyboardEvent).key === 'Enter') {
        ev.preventDefault();
        body.querySelector<HTMLButtonElement>('#perm-deny-add')?.click();
      }
    });

    body.querySelectorAll<HTMLElement>('.btn-perm-remove').forEach((btn) => {
      btn.addEventListener('click', () => {
        const kind = btn.dataset.kind as 'allow' | 'deny';
        const idx = Number(btn.dataset.idx);
        if (!Number.isFinite(idx)) return;
        const list = this.permissions[kind].filter((_, i) => i !== idx);
        this.permissions = { ...this.permissions, [kind]: list };
        void this.applyPermissions(body);
      });
    });
  }

  /** Reenvía la configuración completa al motor y persiste el espejo local en localStorage. */
  private async applyPermissions(body: HTMLElement): Promise<void> {
    if (!this.core) return;
    try {
      await this.core.setPermissions(this.permissions.mode, this.permissions.allow, this.permissions.deny);
      savePermissionsToStorage(this.permissions);
      this.permissionsError = null;
      updatePermissionBadge(this.permissions.mode);
    } catch (e) {
      // lo que se ve es lo vigente. Si la persona no lo permitió
      // (o el motor lo rechazó) se relee el motor y se dice en una línea.
      const text = errText(e);
      let message = text.includes('E_NATIVE_CONSENT_REQUIRED')
        ? 'No se cambió: no se permitió en la ventana de DevAgents.'
        : `No se cambió: ${text}`;
      try {
        const live = await this.core.getPermissions();
        if (live && typeof live.mode === 'string') {
          this.permissions = { mode: live.mode, allow: Array.isArray(live.allow) ? live.allow : [], deny: Array.isArray(live.deny) ? live.deny : [] };
          savePermissionsToStorage(this.permissions);
          updatePermissionBadge(this.permissions.mode);
        }
      } catch (readError) {
        message += ` Tampoco se pudo releer lo vigente: ${errText(readError)}`;
      }
      this.permissionsError = message;
    }
    this.permissionsNote = null;
    this.setSectionMarkup(body, this.permissionsMarkup());
    this.bindPermissionsEvents(body);
  }

  /** borra el recuerdo del host; Auto y Omitir vuelven a preguntar. */
  private async forgetElevatedPermissions(body: HTMLElement): Promise<void> {
    if (!this.core) return;
    try {
      await this.core.forgetElevatedPermissions();
      this.permissionsError = null;
      this.permissionsNote = 'Hecho: la próxima vez que elijas Auto u Omitir permisos, DevAgents volverá a pedir confirmación.';
    } catch (e) {
      this.permissionsNote = null;
      this.permissionsError = `No se pudo olvidar la confirmación: ${errText(e)}`;
    }
    this.setSectionMarkup(body, this.permissionsMarkup());
    this.bindPermissionsEvents(body);
  }

  // -------------------------------------------------------------- Apariencia

  private renderAppearanceSection(): void {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body) return;

    // (c/e): Apariencia como la página 5 de la maqueta: tres
    // tarjetas (Disposición, Tema y Ventana); disposiciones a lo ancho con su
    // croquis, temas en losetas con tres bloques de color y lo elegido en el
    // ámbar de la maqueta. Este módulo no importa layout.ts (las pruebas lo
    // cargan con importaciones simuladas): lee <html data-layout> y pide el
    // cambio con un evento que atiende initLayout. C lleva el grafo de la orden
    // fijo arriba de la conversación.
    const layoutNow = document.documentElement.dataset.centro === '1' ? 'C' : document.documentElement.dataset.layout === 'A' ? 'A' : 'B';
    const layouts: Array<[string, string, string, boolean]> = [
      ['B', 'B · Unificada', 'Secciones plegables en un solo panel (por defecto); se oculta con Ctrl+B y aparece flotando al pasar el ratón.', true],
      ['A', 'A · IDE clásica', 'Barra de iconos y barra lateral por vista.', true],
      ['C', 'C · Centro de mando', 'Como la Unificada, con el grafo de la orden siempre visible y fijo arriba de la conversación.', true],
    ];
    const layoutCards = layouts
      .map(([id, name, hint, enabled]) => {
        const active = enabled && id === layoutNow;
        return `<button class="settings-choice btn-layout" type="button" data-layout="${id}" role="radio" aria-checked="${active}" tabindex="${active ? 0 : -1}"${enabled ? '' : ' disabled aria-disabled="true"'}
                title="${enabled ? 'Usar esta disposición' : 'Aún no disponible'}">
          ${this.layoutSketch(id)}
          <b>${esc(name)}${enabled ? '' : ' <span class="settings-tag settings-tag--falta">Próximamente</span>'}</b>
          <small>${esc(hint)}</small>
        </button>`;
      })
      .join('');
    const layoutBlock = `
        <div class="card">
          <div class="card__title">Disposición de la ventana</div>
          <div class="card__subtitle">Se aplica al momento. Las tres conservan las ventanas de la derecha.</div>
          <div class="settings-layouts" role="radiogroup" aria-label="Disposición de la ventana">${layoutCards}</div>
        </div>`;
    // Grupo de opción única (radiogroup): Tab entra en la elegida y las
    // flechas cambian entre las disponibles; tras repintar, el foco vuelve a
    // la tarjeta elegida para no perder la posición del teclado.
    const choose = (id: string | undefined): void => {
      if (id !== 'A' && id !== 'B') return;
      document.dispatchEvent(new CustomEvent('devagents:set-layout', { detail: id }));
      this.renderAppearanceSection();
      body.querySelector<HTMLElement>(`.btn-layout[data-layout="${id}"]`)?.focus();
    };
    const bindLayouts = (): void => {
      const cards = Array.from(body.querySelectorAll<HTMLButtonElement>('.btn-layout:not([disabled])'));
      cards.forEach((btn, i) => {
        btn.addEventListener('click', () => choose(btn.dataset.layout));
        btn.addEventListener('keydown', (ev) => {
          const step = ev.key === 'ArrowRight' || ev.key === 'ArrowDown' ? 1 : ev.key === 'ArrowLeft' || ev.key === 'ArrowUp' ? -1 : 0;
          if (!step) return;
          ev.preventDefault();
          choose(cards[(i + step + cards.length) % cards.length].dataset.layout);
        });
      });
    };

    const tm = (window as unknown as { themeManager?: ThemeManagerLike }).themeManager;
    if (!tm) {
      this.setSectionMarkup(body, `<div class="col" style="gap:12px">${layoutBlock}<div class="empty-state">${icons.alert(22)}<span class="empty-state__title">Gestor de temas no disponible</span><span>window.themeManager no está inicializado todavía.</span></div></div>`);
      bindLayouts();
      return;
    }

    const current = tm.getCurrentThemeId();
    const themes = tm.getAvailableThemes();
    const tiles = themes
      .map((t) => {
        const active = t.id === current;
        return `<button class="settings-choice settings-theme btn-theme${active ? ' is-active' : ''}" type="button" data-theme="${escapeAttribute(t.id)}" aria-pressed="${active}" title="Aplicar el tema ${escapeAttribute(t.name)}">
          <span class="settings-theme__sw" aria-hidden="true">${this.themeSwatches(t)}</span>
          <span class="settings-theme__name">${esc(t.name)}</span>
        </button>`;
      })
      .join('');

    this.setSectionMarkup(body, `
      <div class="col" style="gap:12px">
        ${layoutBlock}
        <div class="card">
          <div class="card__title">Tema</div>
          <div class="card__subtitle">${themes.length} temas; el editor sigue al tema. «DevAgents Ámbar (maqueta)» es la paleta de la maqueta aprobada y la de por defecto.</div>
          <div class="settings-themes">${tiles}</div>
        </div>
        ${this.windowCardMarkup()}
      </div>`);
    bindLayouts();
    this.bindWindowCard(body);

    body.querySelectorAll<HTMLElement>('.btn-theme').forEach((btn) => {
      btn.addEventListener('click', () => {
        const id = btn.dataset.theme;
        if (id) {
          tm.applyTheme(id);
          this.renderAppearanceSection();
        }
      });
    });
  }

  /** Tres muestras del tema (fondo, superficie y acento), como la maqueta. */
  private themeSwatches(t: { id: string }): string {
    const c = (t as unknown as { colors?: { bgApp?: string; surface2?: string; accent?: string; highlight?: string } }).colors;
    if (!c) return '';
    const sw = (v?: string): string => (v ? `<i style="background:${escapeAttribute(v)}"></i>` : '');
    return sw(c.bgApp) + sw(c.surface2) + sw(c.highlight ?? c.accent);
  }

  /** Tarjeta «Ventana» de Apariencia (maqueta, pág. 5). */
  private windowCardMarkup(): string {
    const zoom = Math.round((Number(document.documentElement.style.zoom) || 1) * 100);
    const falta = '<span class="settings-tag settings-tag--falta">Próximamente</span>';
    const row = (k: string, hint: string, control: string): string =>
      `<div class="settings-row"><div class="settings-row__k"><b>${k}</b>${hint ? `<small>${hint}</small>` : ''}</div><div class="settings-row__v">${control}</div></div>`;
    return `<div class="card" id="window-card"><div class="card__title">Ventana</div>
      ${row('Pantalla de arranque', 'Solo el icono aprobado mientras el motor se prepara; desaparece en cuanto responde. Respeta «reducir movimiento» del sistema.', `<input type="checkbox" class="sw" id="splash-toggle" ${splashEnabled() ? 'checked' : ''} aria-label="Pantalla de arranque" />`)}
      ${row('Zoom', 'También con Ctrl + / Ctrl − / Ctrl 0 y la paleta.', `<span class="modes-stepper"><button type="button" id="zoom-out" aria-label="Reducir zoom">−</button><span id="zoom-value" aria-live="polite">${zoom} %</span><button type="button" id="zoom-in" aria-label="Aumentar zoom">+</button></span><button class="btn btn--sm" type="button" id="zoom-reset">100 %</button>`)}
      ${row('Idioma', 'Idioma de la interfaz. Tus mensajes y las respuestas de los modelos no se traducen.', `<select class="select" id="lang-select" aria-label="Idioma"><option value="es" ${getLang() === 'es' ? 'selected' : ''}>Español</option><option value="en" ${getLang() === 'en' ? 'selected' : ''}>English</option></select>`)}
    </div>`;
  }

  private bindWindowCard(body: HTMLElement): void {
    body.querySelector<HTMLSelectElement>('#lang-select')?.addEventListener('change', (e) => {
      setLang((e.target as HTMLSelectElement).value === 'en' ? 'en' : 'es');
    });
    body.querySelector<HTMLInputElement>('#splash-toggle')?.addEventListener('change', (e) => {
      setSplashEnabled((e.target as HTMLInputElement).checked);
    });
    const set = (delta: number | null): void => {
      document.dispatchEvent(new CustomEvent('devagents:zoom', { detail: delta }));
      const v = body.querySelector<HTMLElement>('#zoom-value');
      if (v) v.textContent = `${Math.round((Number(document.documentElement.style.zoom) || 1) * 100)} %`;
    };
    body.querySelector('#zoom-in')?.addEventListener('click', () => set(10));
    body.querySelector('#zoom-out')?.addEventListener('click', () => set(-10));
    body.querySelector('#zoom-reset')?.addEventListener('click', () => set(null));
  }

  /** Croquis de cada disposición (maqueta, layoutSvg), solo con tokens. */
  private layoutSketch(id: string): string {
    const side =
      id === 'A'
        ? '<rect x="3" y="3" width="8" height="64" fill="var(--bg-activitybar)"/><rect x="13" y="3" width="26" height="64" fill="var(--bg-sidebar)"/>'
        : id === 'B'
          ? '<rect x="3" y="3" width="32" height="64" fill="var(--bg-sidebar)"/><rect x="6" y="8" width="20" height="3" fill="var(--fg-subtle)"/><rect x="6" y="15" width="24" height="3" fill="var(--border)"/><rect x="6" y="22" width="24" height="3" fill="var(--border)"/>'
          : '<rect x="3" y="3" width="26" height="64" fill="var(--bg-sidebar)"/><rect x="31" y="3" width="56" height="22" fill="var(--accent-soft)" stroke="var(--accent)"/>';
    const mx = id === 'A' ? 41 : id === 'B' ? 37 : 31;
    const my = id === 'C' ? 27 : 3;
    const mw = id === 'A' ? 46 : id === 'B' ? 50 : 56;
    const mh = id === 'C' ? 40 : 64;
    const cards = [6, 20, 34].map((y) => `<rect x="91" y="${y}" width="24" height="12" rx="2" fill="var(--surface-2)"/>`).join('');
    return `<svg viewBox="0 0 120 70" width="100%" height="70" aria-hidden="true" focusable="false"><rect x="0.5" y="0.5" width="119" height="69" rx="5" fill="var(--bg-main)" stroke="var(--border)"/>${side}<rect x="${mx}" y="${my}" width="${mw}" height="${mh}" fill="var(--surface-1)"/>${cards}</svg>`;
  }

  // -------------------------------------------------------- Agentes externos

  /**
 * (e): «Agentes externos» de la página 5 de la maqueta. Reúne lo
   * que vivía repartido entre el selector de modelos (ruta, esfuerzo) y la
   * barra de estado (cuota), con los datos reales del motor:
   * core.external.agents/refresh/paths/options/limits. 9-nov (censo de salida):
   * «Activo en DevAgents» usa las preferencias de modelo del motor (oculto en
   * los selectores y fuera de Automático) y «Lo que hereda» dice la política
   * real de contexto y qué archivos de instrucciones hay en la carpeta abierta.
   */
  private async renderAgentsSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;
    this.setSectionMarkup(body, this.loadingBlock('Consultando los agentes externos…'));
    const core = this.core;
    let agents: ExternalAgentRow[] = [];
    let paths: Record<string, string> = {};
    let limits: { task_timeout_ms: number; task_max_turns: number; order_timeout_ms: number; order_max_turns: number } | null = null;
    let quotas: Array<{ cli: string; five_hour: { used_percent: number | null; reset_at: string | null }; daily: { used_percent: number | null; reset_at: string | null }; weekly: { used_percent: number | null; reset_at: string | null } }> = [];
    let loadError = '';
    let selection: ModelSelection[] = [];
    let rootEntries: string[] = [];
    try {
      const results = await Promise.allSettled([
        core.getExternalAgents(),
        core.getExternalPaths(),
        core.getExternalLimits(),
        core.getCliQuotas(),
        core.modelSelection ? core.modelSelection() : Promise.resolve([] as ModelSelection[]),
        core.listDir(''),
      ]);
      if (results[4].status === 'fulfilled' && Array.isArray(results[4].value)) selection = results[4].value;
      if (results[5].status === 'fulfilled') rootEntries = (results[5].value?.entries ?? []).map((e) => String(e.name ?? ''));
      if (results[0].status === 'fulfilled') agents = results[0].value as ExternalAgentRow[];
      else loadError = errText(results[0].reason);
      if (results[1].status === 'fulfilled') paths = results[1].value ?? {};
      if (results[2].status === 'fulfilled') limits = results[2].value;
      if (results[3].status === 'fulfilled') quotas = results[3].value as typeof quotas;
    } catch (e) {
      loadError = errText(e);
    }
    if (this.section !== 'agents') return;

    const falta = '<span class="settings-tag settings-tag--falta">Próximamente</span>';
    const row = (k: string, hint: string, control: string): string =>
      `<div class="settings-row"><div class="settings-row__k"><b>${k}</b>${hint ? `<small>${hint}</small>` : ''}</div><div class="settings-row__v">${control}</div></div>`;
    const sessionText: Record<string, string> = {
      suscripcion: 'Suscripción',
      api_key: 'Clave API',
      sin_sesion: 'Sin sesión iniciada',
      desconocida: 'Sesión desconocida',
    };
    // Política de contexto del motor (external_context.zig,): las
    // instrucciones DEL PROYECTO se respetan; las personales del equipo (memoria,
    // instrucciones globales) no se pasan, para que la orden no dependa de tu
    // configuración. Las habilidades y los MCP propios del agente se conservan.
    const inherits: Record<string, { proyecto: string[]; personal: string[] }> = {
      'claude-code': { proyecto: ['CLAUDE.md', '.claude/', '.mcp.json'], personal: ['~/.claude/CLAUDE.md', '~/.claude/rules/', 'memoria automática'] },
      codex: { proyecto: ['AGENTS.md (DevAgents lo incluye en el encargo)'], personal: ['AGENTS.md de CODEX_HOME', 'memorias'] },
      'gemini-cli': { proyecto: ['GEMINI.md', '.gemini/'], personal: ['~/.gemini/GEMINI.md'] },
      opencode: { proyecto: ['AGENTS.md', 'opencode.json', '.opencode/'], personal: ['configuración global de OpenCode', 'instrucciones de Claude Code'] },
    };
    inherits.claude = inherits['claude-code'];
    inherits.gemini = inherits['gemini-cli'];
    const present = new Set(rootEntries.map((n) => n.toLowerCase()));
    const fileTag = (f: string): string => {
      const base = f.split(' ')[0].replace(/\/$/, '').toLowerCase();
      const local = !f.startsWith('~') && !f.includes(' ') ? present.has(base) : null;
      return `<code title="${local === null ? '' : local ? 'Está en la carpeta abierta' : 'No está en la carpeta abierta'}">${esc(f)}${local ? ' ✓' : ''}</code>`;
    };
    const pct = (w: { used_percent: number | null; reset_at: string | null }, name: string): string => {
      const p = w.used_percent;
      const known = p !== null && Number.isFinite(p);
      return `<span class="settings-quota"><small>${esc(name)} · ${known ? `${Math.round(p as number)} %` : 'sin dato'}</small><span class="settings-quota__bar"><i style="width:${known ? Math.max(0, Math.min(100, p as number)) : 0}%"></i></span><small>${w.reset_at ? `Reinicio ${esc(String(w.reset_at))}` : '&nbsp;'}</small></span>`;
    };

    const detection = `<div class="card">${row('Detección', 'Busca Claude Code, Codex, Gemini CLI y OpenCode instalados y sus modelos.', `<button class="btn" id="agents-refresh" type="button">${icons.refresh(13)} Volver a detectar</button>`)}<div id="agents-msg"></div></div>`;
    // USUARIO-NUEVO A3 (10-nov): herencia de instrucciones personales.
    const inherit = limits ? (limits as { inherit_personal_context?: boolean | null }).inherit_personal_context : undefined;
    const inheritCard = limits
      ? `<div class="card">${row(
          'Heredar mis instrucciones personales',
          'Apagado (por defecto): los agentes reciben las instrucciones del proyecto, pero no las tuyas de equipo (AGENTS.md de tu carpeta de Codex, ~/.claude/CLAUDE.md, la configuración global de OpenCode), para que la orden no dependa de tu máquina. Codex no permite separar solo esas: con un AGENTS.md personal no arranca. Encendido: cada agente usa tu configuración tal como funciona en tu terminal o en tu otra IDE.',
          inherit === null
            ? '<span class="subtle" style="color:var(--warning)">No se pudo leer el ajuste guardado</span>'
            : `<input type="checkbox" class="sw" id="agents-inherit" ${inherit ? 'checked' : ''} aria-label="Heredar mis instrucciones personales" />`
        )}<div id="inherit-msg"></div></div>`
      : '';
    const limitsCard = limits
      ? `<div class="card"><div class="card__title">Límites de los agentes externos</div><div class="card__subtitle">Tiempo y turnos máximos por tarea y por orden, para todos los agentes externos. 0 = sin tope en ese eje.</div>
          ${row('Por tarea', '', `<label class="settings-inline"><span>Minutos</span><input class="input" type="number" min="0" id="lim-task-min" value="${Math.round(limits.task_timeout_ms / 60000)}" /></label><label class="settings-inline"><span>Turnos</span><input class="input" type="number" min="0" id="lim-task-turns" value="${limits.task_max_turns}" /></label>`)}
          ${row('Por orden', '', `<label class="settings-inline"><span>Minutos</span><input class="input" type="number" min="0" id="lim-order-min" value="${Math.round(limits.order_timeout_ms / 60000)}" /></label><label class="settings-inline"><span>Turnos</span><input class="input" type="number" min="0" id="lim-order-turns" value="${limits.order_max_turns}" /></label>`)}
          ${row('', '', '<button class="btn btn--primary" id="lim-save" type="button">Guardar límites</button>')}<div id="lim-msg"></div></div>`
      : '';

    const cards = agents.map((a) => {
      const cli = String(a.cli || '').toLowerCase();
      const isCodex = cli === 'codex';
      const efforts = [...new Set((a.models ?? []).flatMap((m) => m.reasoning_efforts ?? []))];
      const currentEffort = (a.models ?? []).find((m) => m.reasoning_effort)?.reasoning_effort ?? '';
      const q = quotas.find((x) => x.cli === cli || (cli.startsWith('claude') && x.cli === 'claude-code'));
      const inh = inherits[cli] ?? { proyecto: [], personal: [] };
      const agentRows = selection.filter((x) => x.provider === a.provider && x.text_gen !== false);
      const active = agentRows.length === 0 || agentRows.some((x) => x.show_in_selectors !== false);
      const roleTag = (name: string, ok: boolean): string => `<span class="settings-tag ${ok ? 'settings-tag--ok' : ''}">${ok ? icons.check(10) : icons.close(10)} ${name}</span>`;
      const id = escapeAttribute(cli);
      return `<div class="card agent-card" data-cli="${id}">
        <div class="card__title">${esc(a.display || a.cli)} <span class="settings-tag settings-tag--ok">detectado${a.version ? ' ' + esc(a.version) : ''}</span></div>
        <div class="card__subtitle">${esc(sessionText[a.session] ?? a.session)}${a.authenticode ? ' · ' + esc(({ trusted: 'firma verificada', not_trusted: 'firma sin verificar', unsigned: 'sin firma' } as Record<string, string>)[a.authenticode] ?? a.authenticode) : ''}${a.session_reason ? ' · ' + esc(a.session_reason) : ''}</div>
        ${row('Activo en DevAgents', 'Apagado no se desinstala: deja de salir en Modelo y en Colmena y DevAgents no lo usa en Automático.', `<input type="checkbox" class="sw agent-active" data-cli="${id}" ${active ? 'checked' : ''} aria-label="Activo en DevAgents: ${escapeAttribute(a.display || a.cli)}" />`)}
        ${row('Ruta del ejecutable', 'Vacía = versión más reciente detectada.', `<input class="input agent-path" id="agent-path-${id}" aria-label="Ruta del ejecutable de ${escapeAttribute(a.display || a.cli)}" placeholder="Automática" value="${escapeAttribute(paths[cli] ?? '')}" /><button class="btn agent-path-apply" data-cli="${id}" type="button">Aplicar</button>`)}
        ${a.exe ? `<div class="card__subtitle" style="margin-top:4px">En uso: <code>${esc(a.exe)}</code></div>` : ''}
        ${a.acl_orphan_note ? `<div class="card__subtitle agent-orphan" style="margin-top:4px">Permisos de la instalación: ${esc(a.acl_orphan_note)}</div>` : ''}
        ${(a.acl_appcontainer_writers ?? []).map((w) => `<div class="card__subtitle agent-acl-writer" style="margin-top:4px">Permisos de la instalación: ${w.app ? `la app «${esc(w.app)}»` : 'una app ya desinstalada'} (<code>${esc(w.sid)}</code>) puede modificarla. Se acepta porque es una sola aplicación y no otro usuario; «Comprobar equipo», en Ayuda, explica cómo quitar ese permiso.</div>`).join('')}
        ${(a.rejected ?? []).map((r) => `<div class="card__subtitle agent-rejected" style="margin-top:4px">Se encontró también <code>${esc(r.path)}</code>${r.version ? ` (${esc(r.version)})` : ''}, descartada: ${esc(r.reason)}</div>`).join('')}
        ${a.ignored_env ? `<div class="card__subtitle" style="margin-top:4px">DevAgents no le pasa ${esc(a.ignored_env)} de tu entorno: la CLI usa la sesión con la que la iniciaste y DevAgents nunca factura por API a través de ella.</div>` : ''}
        ${a.enumeration_reason ? `<div class="card__subtitle" style="margin-top:4px;color:var(--warning)">${esc(a.enumeration_reason)}</div>` : ''}
        ${efforts.length ? row('Esfuerzo por defecto', 'Se aplica a todos sus modelos.', `<select class="select agent-effort" id="agent-effort-${id}" data-cli="${id}" aria-label="Esfuerzo por defecto de ${escapeAttribute(a.display || a.cli)}"><option value="">Por defecto</option>${efforts.map((e) => `<option value="${escapeAttribute(e)}" ${e === currentEffort ? 'selected' : ''}>${esc(e)}</option>`).join('')}</select>`) : ''}
        ${row('Roles que puede asumir', 'Solo Codex habla el protocolo de plan y veredicto.', `${roleTag('Planificador', isCodex)} ${roleTag('Ejecutor', true)} ${roleTag('Auditor', isCodex)}`)}
        ${row('Cuota', 'Al agotarse avisa y la CLI se omite.', q ? `${pct(q.five_hour, '5 h')}${pct(q.daily, 'Diaria')}${pct(q.weekly, 'Semanal')}` : '<span class="subtle">no medida</span>')}
        ${row('Instrucciones y ajustes que hereda', 'Las del proyecto se respetan (✓ = está en la carpeta abierta). Las personales de tu equipo no se le pasan, para que la orden no dependa de tu configuración; sus skills y MCP propios se conservan.', `<span class="settings-files"><small>Del proyecto:</small> ${inh.proyecto.map(fileTag).join('')}</span><span class="settings-files"><small>No se pasan:</small> ${inh.personal.map((f) => `<code>${esc(f)}</code>`).join('')}</span>`)}
        <div id="agent-msg-${id}"></div>
      </div>`;
    }).join('');

    const empty = loadError
      ? `<div class="card" style="color:var(--danger)">No se pudieron consultar los agentes externos: ${esc(loadError)}</div>`
      : agents.length ? '' : `<div class="empty-state">${icons.externalAgent(22)}<span class="empty-state__title">Ningún agente externo detectado</span><span>Instala Claude Code, Codex, Gemini CLI u OpenCode y pulsa «Volver a detectar».</span></div>`;
    this.setSectionMarkup(body, `<div class="col" style="gap:12px">${detection}${empty}${cards}${inheritCard}${limitsCard}</div>`);

    const msg = (id: string, text: string, ok: boolean): void => {
      const el = body.querySelector<HTMLElement>(`#${id}`);
      if (el) { el.textContent = text; el.style.color = ok ? 'var(--success)' : 'var(--danger)'; }
    };
    body.querySelector<HTMLInputElement>('#agents-inherit')?.addEventListener('change', async (ev) => {
      const sw = ev.currentTarget as HTMLInputElement;
      const on = sw.checked;
      sw.disabled = true;
      try {
        await core.setExternalLimits({ inherit_personal_context: on });
        msg('inherit-msg', on ? 'Los agentes usarán tus instrucciones personales.' : 'Los agentes ya no reciben tus instrucciones personales.', true);
      } catch (e) {
        sw.checked = !on;
        msg('inherit-msg', 'No se pudo guardar: ' + errText(e), false);
      } finally {
        sw.disabled = false;
      }
    });
    body.querySelector('#agents-refresh')?.addEventListener('click', async () => {
      msg('agents-msg', 'Detectando…', true);
      try { await core.refreshExternalAgents(); await this.renderAgentsSection(); }
      catch (e) { msg('agents-msg', 'No se pudo volver a detectar: ' + errText(e), false); }
    });
    body.querySelectorAll<HTMLButtonElement>('.agent-path-apply').forEach((btn) => {
      btn.addEventListener('click', async () => {
        const cli = btn.dataset.cli || '';
        const value = body.querySelector<HTMLInputElement>(`#agent-path-${cli}`)?.value.trim() ?? '';
        try {
          const next = { ...paths, [cli]: value };
          if (!value) delete next[cli];
          await core.setExternalPaths(next);
          paths = next;
          msg(`agent-msg-${cli}`, value ? 'Ruta aplicada.' : 'Vuelve a la versión más reciente.', true);
        } catch (e) { msg(`agent-msg-${cli}`, 'No se pudo aplicar la ruta: ' + errText(e), false); }
      });
    });
    body.querySelectorAll<HTMLInputElement>('.agent-active').forEach((sw) => {
      sw.addEventListener('change', async () => {
        const cli = sw.dataset.cli || '';
        const agent = agents.find((x) => String(x.cli).toLowerCase() === cli);
        if (!agent) return;
        const on = sw.checked;
        sw.disabled = true;
        try {
          // Solo los modelos de texto que no estén ya así: un agente puede traer
          // cientos (OpenCode, 167) y cada cambio pasa por la cola del puente.
          const current = new Map(selection.filter((x) => x.provider === agent.provider).map((x) => [x.model, x]));
          const todo = (agent.models ?? []).filter((m) => {
            const c = current.get(m.slug);
            return c ? c.text_gen !== false && (c.show_in_selectors !== on || c.allow_automatic !== on) : true;
          });
          let done = 0;
          for (const m of todo) {
            await core.setModelPreferences(agent.provider, m.slug, on, on);
            done++;
            if (done % 10 === 0 || done === todo.length) msg(`agent-msg-${cli}`, `Aplicando ${done}/${todo.length}…`, true);
            const c = current.get(m.slug);
            if (c) { c.show_in_selectors = on; c.allow_automatic = on; }
          }
          if (!on) {
            // Apagado y fijado en la orden: se suelta, o la orden seguiría usándolo.
            const [exec, plan] = await Promise.all([
              core.getExecModel().catch(() => ({ provider: '', model: '' })),
              core.getPlanModel().catch(() => ({ provider: '', model: '' })),
            ]);
            if (exec?.provider === agent.provider) await core.setExecModel('', '');
            if (plan?.provider === agent.provider) await core.setPlanModel('', '');
            try {
              if ((localStorage.getItem('devagents.orderModel.v1') || '').startsWith(agent.provider + '|')) localStorage.removeItem('devagents.orderModel.v1');
            } catch { /* sin almacenamiento */ }
          }
          document.dispatchEvent(new CustomEvent('devagents:models-changed'));
          msg(`agent-msg-${cli}`, on ? 'Activo: vuelve a salir en Modelo y en Colmena.' : 'Apagado: ya no sale en Modelo ni en Colmena ni se usa en Automático.', true);
        } catch (e) {
          sw.checked = !on;
          msg(`agent-msg-${cli}`, 'No se pudo cambiar: ' + errText(e), false);
        } finally {
          sw.disabled = false;
        }
      });
    });
    body.querySelectorAll<HTMLSelectElement>('.agent-effort').forEach((sel) => {
      sel.addEventListener('change', async () => {
        const cli = sel.dataset.cli || '';
        const agent = agents.find((x) => String(x.cli).toLowerCase() === cli);
        try {
          for (const m of agent?.models ?? []) {
            if ((m.reasoning_efforts ?? []).length) await core.setExternalModelOptions(agent!.provider, m.slug, sel.value);
          }
          msg(`agent-msg-${cli}`, 'Esfuerzo aplicado a sus modelos.', true);
        } catch (e) { msg(`agent-msg-${cli}`, 'No se pudo aplicar el esfuerzo: ' + errText(e), false); }
      });
    });
    body.querySelector('#lim-save')?.addEventListener('click', async () => {
      const num = (id: string): number => Math.max(0, Number(body.querySelector<HTMLInputElement>(`#${id}`)?.value) || 0);
      try {
        await core.setExternalLimits({
          task_timeout_ms: num('lim-task-min') * 60000,
          task_max_turns: num('lim-task-turns'),
          order_timeout_ms: num('lim-order-min') * 60000,
          order_max_turns: num('lim-order-turns'),
        });
        msg('lim-msg', 'Límites guardados.', true);
      } catch (e) { msg('lim-msg', 'No se pudieron guardar los límites: ' + errText(e), false); }
    });
  }

  // ------------------------------------------------------------------ Acerca de

  private async renderAboutSection(): Promise<void> {
    const body = this.container.querySelector<HTMLElement>('#settings-body');
    if (!body || !this.core) return;

    if (!this.aboutLoaded) {
      this.setSectionMarkup(body, this.loadingBlock('Consultando estado del motor…'));
      try {
        const [status, catalog] = await Promise.all([this.core.status(), this.core.catalogInfo()]);
        this.aboutStatus = status;
        this.aboutCatalogPath = catalog.catalog_path_abs;
        this.aboutError = null;
      } catch (e) {
        this.aboutError = errText(e);
      }
      this.aboutLoaded = true;
    }

    this.setSectionMarkup(body, this.aboutMarkup());
    this.bindHelpCard(body);
    // Tanda 5 (F0.4): interruptor, «Buscar ahora», último resultado y lo
    // preparado para instalar al cerrar (components/update_view.ts).
    const core = this.core;
    sharedUpdateController(() => new UpdateController(core, { raise: raiseAlert, clear: clearAlert }))
      ?.attach(body.querySelector<HTMLElement>('#update-card'));
  }

  /** Botones de Ayuda: abren el panel de ayuda (preguntas y diagnóstico) o el tutorial. */
  private bindHelpCard(body: HTMLElement): void {
    const help = (): void => { document.dispatchEvent(new CustomEvent('devagents:open-help')); };
    body.querySelector('#help-open-faq')?.addEventListener('click', help);
    body.querySelector('#help-open-diag')?.addEventListener('click', help);
    body.querySelector('#help-tutorial')?.addEventListener('click', () => window.dispatchEvent(new CustomEvent('devagents:show-onboarding')));
    const toggle = body.querySelector<HTMLButtonElement>('#help-shortcuts');
    const editor = body.querySelector<HTMLElement>('#shortcuts-editor');
    toggle?.addEventListener('click', () => {
      if (!editor) return;
      editor.hidden = !editor.hidden;
      toggle.setAttribute('aria-expanded', String(!editor.hidden));
      if (!editor.hidden) this.renderShortcutsEditor(editor);
    });
  }

  /**
 * F6 (10-nov): lista de comandos con su atajo. «Cambiar» graba la
   * siguiente combinación (Esc cancela); si otro comando la tenía, la pierde y
   * se avisa. Se guarda en este equipo (app/keybindings.ts).
   */
  private renderShortcutsEditor(host: HTMLElement, recordingId = '', message = ''): void {
    const cmds = bindableCommands().slice().sort((a, b) => (a.category ?? '').localeCompare(b.category ?? '') || a.label.localeCompare(b.label));
    const rows = cmds.map((c) => {
      const combo = effectiveShortcut(c.id);
      const recording = recordingId === c.id;
      return `<div class="shortcut-row${recording ? ' is-recording' : ''}" data-cmd="${escapeAttribute(c.id)}">
          <span class="shortcut-row__cat">${esc(c.category ?? '')}</span>
          <span class="shortcut-row__label">${esc(c.label)}${isCustomized(c.id) ? ' <span class="settings-tag">cambiado</span>' : ''}</span>
          <kbd class="shortcut-row__kbd">${recording ? 'Pulsa la combinación… (Esc cancela)' : esc(combo || '—')}</kbd>
          <span class="shortcut-row__actions">
            <button class="btn btn--sm" type="button" data-sc-action="record">${recording ? 'Grabando…' : 'Cambiar'}</button>
            <button class="icon-btn" type="button" data-sc-action="clear" title="Quitar el atajo" aria-label="Quitar el atajo de ${escapeAttribute(c.label)}" ${combo ? '' : 'disabled'}>${icons.close(13)}</button>
            <button class="icon-btn" type="button" data-sc-action="reset" title="Restablecer el atajo por defecto" aria-label="Restablecer ${escapeAttribute(c.label)}" ${isCustomized(c.id) ? '' : 'disabled'}>${icons.refresh(13)}</button>
          </span>
        </div>`;
    }).join('');
    host.innerHTML = `
      <div class="shortcuts-editor__head">
        <span class="subtle">${esc(message || 'Los atajos llevan Ctrl o Alt, o son una tecla F. Se guardan en este equipo.')}</span>
        <button class="btn btn--sm" type="button" data-sc-action="reset-all">Restablecer todos</button>
      </div>
      <div class="shortcuts-editor__list">${rows || '<div class="empty-state"><span>La paleta aún no tiene comandos.</span></div>'}</div>`;
    host.querySelector('[data-sc-action="reset-all"]')?.addEventListener('click', () => {
      resetShortcut();
      this.renderShortcutsEditor(host, '', 'Atajos restablecidos.');
    });
    host.querySelectorAll<HTMLElement>('.shortcut-row').forEach((row) => {
      const id = row.dataset.cmd ?? '';
      row.querySelector('[data-sc-action="clear"]')?.addEventListener('click', () => { setShortcut(id, ''); this.renderShortcutsEditor(host); });
      row.querySelector('[data-sc-action="reset"]')?.addEventListener('click', () => { resetShortcut(id); this.renderShortcutsEditor(host); });
      row.querySelector('[data-sc-action="record"]')?.addEventListener('click', () => this.recordShortcut(host, id));
    });
  }

  private recordShortcut(host: HTMLElement, id: string): void {
    this.renderShortcutsEditor(host, id);
    document.body.dataset.recordingShortcut = '1';
    const done = (message: string): void => {
      window.removeEventListener('keydown', onKey, true);
      delete document.body.dataset.recordingShortcut;
      this.renderShortcutsEditor(host, '', message);
    };
    const onKey = (e: KeyboardEvent): void => {
      e.preventDefault();
      e.stopImmediatePropagation();
      if (e.key === 'Escape') { done('Sin cambios.'); return; }
      const combo = comboFromEvent(e);
      if (!combo) return; // solo un modificador: se sigue esperando
      if (!isAssignable(combo)) { this.renderShortcutsEditor(host, id, `«${combo}» no vale: usa Ctrl o Alt, o una tecla F.`); return; }
      const displaced = setShortcut(id, combo);
      const other = displaced ? bindableCommands().find((c) => c.id === displaced)?.label : '';
      done(other ? `«${combo}» asignado; «${other}» se quedó sin atajo.` : `«${combo}» asignado.`);
    };
    window.addEventListener('keydown', onKey, true);
  }

  private aboutMarkup(): string {
    const errBlock = this.aboutError
      ? `<div class="card" style="border-color:var(--danger)"><span style="color:var(--danger)">${esc(this.aboutError)}</span></div>`
      : '';

    const st = this.aboutStatus;
    const rows: Array<[string, string]> = st
      ? [
          ['Versión', formatEngineVersion(st.version)],
          ['PID', String(st.pid ?? '—')],
          ['Motor listo', st.engineReady ? 'sí' : 'no'],
          ['Proveedores', String(st.providerCount ?? 0)],
          ['Claves', String(st.keyCount ?? 0)],
          ['Modo de gobernanza', st.governanceMode || '—'],
          ['Modelo activo', st.activeModel || '—'],
        ]
      : [];

    const initErrorBlock =
      st && st.initError
        ? `<div class="row" style="gap:10px;padding:2px 0"><span class="subtle" style="min-width:180px">Error de inicialización</span><span style="color:var(--danger)">${esc(st.initError)}</span></div>`
        : '';

    return `
      <div class="col" style="gap:16px">
        ${errBlock}
        <div class="card">
          <div class="card__title">Estado del motor</div>
          <div class="card__subtitle">Información de conexión y versión comunicada por el motor de esta cabina.</div>
          <div class="col" style="gap:4px;margin-top:10px">
            ${rows.map(([l, v]) => `<div class="row" style="gap:10px;padding:2px 0"><span class="subtle" style="min-width:180px">${esc(l)}</span><span>${esc(v)}</span></div>`).join('')}
            ${initErrorBlock}
            <div class="row" style="gap:10px;padding:2px 0"><span class="subtle" style="min-width:180px">Ruta del catálogo</span><span class="mono truncate">${esc(this.aboutCatalogPath || '—')}</span></div>
          </div>
        </div>
        <div class="card" id="update-card" aria-live="polite"></div>
        <div class="card" id="help-card">
          <div class="card__title">Ayuda</div>
          <div class="card__subtitle">También en el pie del panel izquierdo y en la paleta.</div>
          <div class="settings-row"><div class="settings-row__k"><b>Preguntas frecuentes</b><small>@-menciones, Spaces y atajos, con buscador.</small></div><div class="settings-row__v"><button class="btn" type="button" id="help-open-faq">Abrir</button></div></div>
          <div class="settings-row"><div class="settings-row__k"><b>Diagnóstico</b><small>Estado del motor y últimos mensajes de consola, para adjuntar a un aviso de fallo.</small></div><div class="settings-row__v"><button class="btn" type="button" id="help-open-diag">Abrir diagnóstico</button></div></div>
          <div class="settings-row"><div class="settings-row__k"><b>Tutorial</b><small>Bienvenida de 4 pasos.</small></div><div class="settings-row__v"><button class="btn" type="button" id="help-tutorial">Repetir tutorial</button></div></div>
          <div class="settings-row"><div class="settings-row__k"><b>Atajos de teclado</b><small>Cambia, quita o restablece el atajo de cada comando de la paleta.</small></div><div class="settings-row__v"><button class="btn" type="button" id="help-shortcuts" aria-expanded="false" aria-controls="shortcuts-editor">Personalizar</button></div></div>
          <div class="shortcuts-editor" id="shortcuts-editor" hidden></div>
        </div>
      </div>`;
  }
}
