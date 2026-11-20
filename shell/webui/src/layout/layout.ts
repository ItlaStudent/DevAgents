import { brandMark, icons } from '../design/icons';
import { notice } from '../design/notice';
import { escapeAttribute } from '../design/html';

export interface EngineStatus {
  online: boolean;
  pid: number;
  version: string;
  governanceMode: string;
  model: string;
  keyLabel: string;
}

/**
 * Etiqueta de versión del motor resuelta en UN solo sitio.
 *
 * La usan la barra de estado y el Monitor para no volver a divergir: antes la
 * plantilla de la barra llevaba `v0.1.0` fijo y el Monitor leía `st.version`
 * sin normalizar, así que el Monitor mostraba «—» aunque el motor tuviera
 * versión. `—` se reserva para cuando el motor de verdad no la publica; nunca
 * se inventa ni se copia de un texto fijo.
 */
export function formatEngineVersion(version?: string | null): string {
  const raw = typeof version === 'string' ? version.trim().replace(/^v/i, '') : '';
  return raw ? `v${raw}` : '—';
}

/**
 * Vistas del área central. `diff` no aparece en la barra de actividad: se
 * alcanza al revisar los cambios de un archivo, no navegando.
 */
export type ViewId =
  | 'agent'
  | 'explorer'
  | 'search'
  | 'monitor'
  | 'spaces'
  | 'mcp'
  | 'issues'
  | 'settings'
  | 'diff';

export const VIEWS: Array<{ id: ViewId; label: string; icon: string }> = [
  { id: 'agent', label: 'Agente', icon: brandMark(19) },
  { id: 'explorer', label: 'Explorador de archivos', icon: icons.files(18) },
  { id: 'search', label: 'Búsqueda global', icon: icons.search(18) },
  { id: 'monitor', label: 'Monitor', icon: icons.monitor(18) },
  { id: 'spaces', label: 'Spaces y sesiones', icon: icons.spaces(18) },
  { id: 'mcp', label: 'Conectores MCP', icon: icons.plug(18) },
  { id: 'issues', label: 'Incidencias del proyecto', icon: icons.issues(18) },
];

/**
 * Esqueleto de la cabina.
 *
 * Solo estructura y clases: ni un color literal. Los contenedores vacios
 * (`#view-*`, `#pane-*`) los rellenan los paneles, y todo el comportamiento
 * (cambio de vista, botones de ventana, pestañas) lo cablea ViewRouter.
 */
export function renderLayout(container: HTMLElement): void {
  container.innerHTML = `
    <div id="beats-app" class="app-shell">

      <header class="titlebar">
        <div class="titlebar__group">
          <!-- El botón de la barra lateral vive aquí, arriba a la izquierda
               (el router mueve #btn-sidebar-collapse). -->
          <span class="titlebar__slot" id="titlebar-sidebar-slot"></span>
          <!-- Atrás y avanzar entre vistas, como VS Code o Cursor (Alt+← / Alt+→). -->
          <span class="titlebar__navpair">
            <button class="win-btn titlebar__nav" id="btn-nav-back" title="Atrás (Alt+←)" aria-label="Atrás" disabled>${icons.arrowLeft(15)}</button>
            <button class="win-btn titlebar__nav" id="btn-nav-forward" title="Avanzar (Alt+→)" aria-label="Avanzar" disabled>${icons.arrowRight(15)}</button>
          </span>
          <button class="win-btn" id="btn-browser" aria-label="Navegador" title="Abrir u ocultar el navegador integrado">${icons.monitor(15)}</button>
          <span class="titlebar__brand">${brandMark(17)} DEVAGENTS</span>
          <span class="titlebar__sep">|</span>
          <span class="titlebar__project" id="project-name">…</span>
        </div>
        <div class="titlebar__group">
          <button class="win-btn" id="btn-attention" title="Avisos de órdenes" aria-label="Avisos de órdenes">${icons.bell(15)}</button>
          <button class="win-btn" id="btn-settings" title="Configuración" aria-label="Configuración">${icons.settings(15)}</button>
          <button class="win-btn" id="btn-command-palette" title="Paleta de comandos (Ctrl+Shift+P)">${icons.search(15)}</button>
          <span class="titlebar__sep" style="margin:0 2px">|</span>
          <button class="win-btn" id="btn-minimize" title="Minimizar">${icons.minimize(15)}</button>
          <button class="win-btn" id="btn-maximize" title="Maximizar">${icons.maximize(13)}</button>
          <button class="win-btn win-btn--close" id="btn-close" title="Cerrar">${icons.close(15)}</button>
        </div>
      </header>

      <div class="body-row">

        <nav class="activity-bar" id="activity-bar">
          ${VIEWS.map(
            (v) =>
              `<button class="activity-bar__item" data-view="${escapeAttribute(v.id)}" id="act-${escapeAttribute(v.id)}" title="${escapeAttribute(v.label)}">${v.icon}</button>`
          ).join('')}
          <button class="activity-bar__item activity-bar__spacer" id="act-help" title="Ayuda y diagnóstico" aria-label="Ayuda y diagnóstico">${icons.book(18)}</button>
          <button class="activity-bar__item" data-view="settings" id="act-settings" title="Configuración">${icons.settings(18)}</button>
          <button class="activity-bar__item" id="act-expand" title="Desplegar panel" aria-label="Desplegar panel" aria-controls="sidebar-primary">${icons.chevronRight(15)}</button>
        </nav>

        <aside class="sidebar" id="sidebar-primary">
          <!-- En B · Unificada cada vista es una sección
               plegable de este mismo panel; el router mueve aquí la cabecera
               de herramientas y #sidebar-body. En A no se usa. -->
          <div class="sidebar__sections scroll-y" id="sidebar-sections"></div>
          <div class="sidebar__header">
            <span class="section-label" id="sidebar-title">Agente</span>
            <div class="row" id="sidebar-header-tools" style="gap:4px">
              <div class="row" id="sidebar-actions"></div>
              <button class="icon-btn" id="btn-sidebar-collapse" title="Plegar barra lateral">${icons.chevronLeft(14)}</button>
            </div>
          </div>
          <div class="sidebar__body scroll-y" id="sidebar-body"></div>
          <div class="sidebar__foot" id="sidebar-foot">
            <button class="sidebar__foot-item" id="sb-foot-settings" title="Configuración">${icons.settings(14)}<span>Configuración</span></button>
            <button class="sidebar__foot-item" id="sb-foot-help" title="Ayuda y diagnóstico">${icons.book(14)}<span>Ayuda y diagnóstico</span></button>
          </div>
        </aside>

        <main class="central" id="central-container">
          <div class="tabs" id="tab-bar">
            <div id="tab-items"></div>
            <button class="btn btn--sm" id="btn-new-conversation" style="margin-left:auto;flex:0 0 auto"
                    title="Empezar una conversación nueva (rompe el hilo actual)">${icons.plus(13)} Nueva conversación</button>
            <div class="switch-group" id="app-mode-switch" style="margin-left:10px;flex:0 0 auto">
              <button class="switch-group__item is-active" id="mode-agent" title="Modo Agente: el superagente planifica y ejecuta la orden">${icons.agentMode(13)} Agente</button>
              <button class="switch-group__item" id="mode-dev" title="Modo Dev: editor de código y explorador de archivos">${icons.code(13)} Dev</button>
            </div>
          </div>
          <div class="editor-area" id="editor-area">
            <div id="pane-mission-container" class="grow"></div>
            <div id="right-cards-host" class="right-cards-host"></div>
            <div id="monaco-editor-container" class="grow" style="display:none"></div>
            <div id="pane-verification-container" class="grow scroll-y" style="display:none"></div>
            <div id="pane-catalog-container" class="grow scroll-y" style="display:none"></div>
            <div id="pane-settings-container" class="grow scroll-y" style="display:none"></div>
            <div id="pane-mcp-container" class="grow scroll-y" style="display:none"></div>
            <div id="pane-issues-container" class="grow scroll-y" style="display:none"></div>
            <div id="pane-monitor-container" class="grow scroll-y" style="display:none"></div>
            <div id="pane-diff-container" class="grow scroll-y" style="display:none"></div>
          </div>
        </main>

        <aside class="panel-secondary" id="panel-secondary" data-collapsed="true">
          <div class="sidebar__header"><span id="side-panel-title">Terminal</span><button class="icon-btn" id="btn-close-side-panel" aria-label="Cerrar panel" title="Cerrar panel">${icons.close(16)}</button></div>
          <div id="chat-host" class="chat-host" style="display:none"></div>
          <div id="right-explorer-body" class="grow scroll-y" style="display:none"></div>
        <section class="panel-bottom" id="panel-bottom">
          <div class="panel-resize panel-resize--v" id="bottom-resize-v" title="Arrastra para cambiar la altura"></div>
          <div class="panel-tabs" id="bottom-tabs">
            <!-- Las pestañas desplazan en su propia franja; la flecha queda
                 FUERA de ella. Dentro, en una columna de 320 px, las cuatro
                 pestañas la empujaban fuera de la vista y no había forma de
                 plegar ni desplegar la terminal. -->
            <div class="panel-tabs__list">
              <button class="panel-tab is-active" data-bottom="terminal" title="Terminal del sistema (ConPTY)">Terminal</button>
              <button class="panel-tab" data-bottom="verification" title="Verificación del entregable en navegador real">Verificación</button>
              <button class="panel-tab" data-bottom="engine" title="Salida de diagnóstico del motor">Salida</button>
              <button class="panel-tab" data-bottom="problems" title="Errores y avisos de la orden activa">Problemas</button>
            </div>
            <!-- E5.22: la terminal es la única pestaña inferior con modo
                 ventana; el botón pregunta a main cuál está activa. -->
            <button class="icon-btn panel-tabs__toggle" id="btn-popout-bottom" title="Abrir la pestaña activa en una ventana nueva">&#10697;</button>
            <button class="icon-btn panel-tabs__toggle" id="btn-toggle-bottom" title="Contraer panel">${icons.chevronDown(14)}</button>
          </div>
          <div class="grow scroll-y code-surface" id="bottom-content" style="padding:10px 14px"></div>
        </section>
        </aside>

      </div>

      <footer class="status-bar">
        <div class="status-bar__group">
          <span class="status-bar__item" id="status-engine">
            <span class="pill__dot" id="status-engine-dot"></span>
            <span id="status-engine-text">Motor: comprobando…</span>
          </span>
          <span class="status-bar__item" id="status-engine-pid">PID <span id="val-pid">--</span></span>
          <span class="status-bar__item status-bar__item--action" id="status-gov-mode" title="Cambiar modo de gobernanza">Gobernanza: —</span>
          <!-- Solo aparece cuando el agente puede actuar sin preguntar. Un modo
               así no debe poder olvidarse: se queda a la vista todo el rato. -->
          <button class="status-bar__item status-bar__item--action" id="status-paid-budget" style="border:0;background:transparent;color:inherit;font:inherit" type="button" aria-live="polite" aria-label="Llamadas de pago restantes; abrir Gobernanza" title="Autorizar más llamadas en Gobernanza">Pago: comprobando…</button>
          <span class="status-bar__item status-bar__item--warn" id="status-permission-mode" style="display:none"></span>
        </div>
        <div class="status-bar__group">
          <span class="status-bar__item status-bar__item--action" id="status-monitor" title="Abrir el Monitor del agente">Monitor</span>
          <span class="status-bar__item status-bar__item--action" id="status-open-design" title="Abrir Open Design">Open Design</span>
          <span class="status-bar__item status-bar__item--action" id="status-model" title="Elegir modelo de planificación">Modelo: —</span>
          <span class="status-bar__item status-bar__item--action" id="status-key-label" title="Gestionar claves API">Claves: —</span>
          <span class="status-bar__item" id="status-ver">—</span>
        </div>
      </footer>

      <!-- Columna del navegador integrado: la barra la pinta esta WebUI y el
           host coloca la página (WebView sin puente) justo debajo. Los estados
           sin página (vacía, error, bloqueada) se pintan en #browser-body. -->
      <div class="bsurf" id="browser-surface" hidden></div>

    </div>
  `;
}

/** Refleja el estado real del motor en la barra inferior. */
export function updateEngineStatus(status: EngineStatus): void {
  const dot = document.getElementById('status-engine-dot');
  const text = document.getElementById('status-engine-text');
  const pid = document.getElementById('val-pid');
  const gov = document.getElementById('status-gov-mode');
  const model = document.getElementById('status-model');
  const keyLabel = document.getElementById('status-key-label');
  const ver = document.getElementById('status-ver');

  if (dot && text && pid) {
    dot.style.background = status.online ? 'var(--success)' : 'var(--danger)';
    text.innerText = status.online ? 'Motor: en línea' : 'Motor: desconectado';
    pid.innerText = status.pid > 0 ? String(status.pid) : '—';
  }
  if (gov) gov.innerText = `Gobernanza: ${status.governanceMode || '—'}`;
  if (model) model.innerText = `Modelo: ${status.model || 'auto'}`;
  if (keyLabel) keyLabel.innerText = `Claves: ${status.keyLabel || '—'}`;
  if (ver) ver.innerText = formatEngineVersion(status.version);
}

/**
 * Refleja en la barra inferior los modos de permiso en los que el agente actúa
 * sin pedir confirmación. En `normal` y `accept_edits` el indicador desaparece:
 * un aviso que sale siempre deja de leerse.
 */
export function updatePermissionBadge(mode: string): void {
  const el = document.getElementById('status-permission-mode');
  if (!el) return;
  const risky: Record<string, string> = {
    bypass: 'BYPASS · el agente actúa sin pedir confirmación',
    autonomous: 'AUTÓNOMO · ejecución desatendida',
  };
  const label = risky[mode];
  if (!label) {
    el.style.display = 'none';
    return;
  }
  el.style.display = '';
  el.textContent = label;
  el.title =
    'Cambia el modo en Configuración → Permisos. Los prefijos denegados se siguen respetando.';
}

/**
 * (c) — disposición de la ventana (maqueta aprobada, págs. 1 y 5).
 *
 * B · Unificada (por defecto): cada vista es una sección plegable de un solo
 * panel izquierdo, con Configuración y Ayuda al pie; plegado, queda la franja
 * de iconos. A · IDE clásica: la cabina de antes (barra de iconos + barra
 * lateral por vista). C · Centro de mando (12-nov, con el grafo de la orden de
 *): la Unificada con el grafo de la orden siempre encendido y fijo
 * arriba de la conversación. Un valor guardado desconocido se lee como B.
 */
export type LayoutId = 'A' | 'B' | 'C';
export const LAYOUT_KEY = 'devagents.layout.v1';

export function readLayout(): LayoutId {
  try {
    const saved = localStorage.getItem(LAYOUT_KEY);
    return saved === 'A' || saved === 'C' ? saved : 'B';
  } catch {
    return 'B';
  }
}

export function applyLayout(id: LayoutId, save: boolean): void {
  const root = document.documentElement;
  root.dataset.layout = id === 'A' ? 'A' : 'B';
  if (id === 'C') root.dataset.centro = '1';
  else delete root.dataset.centro;
  if (save) {
    try {
      localStorage.setItem(LAYOUT_KEY, id);
    } catch (error) {
      notice('No se pudo guardar la disposición de la ventana: ' + String(error), 'error');
    }
  }
  document.dispatchEvent(new CustomEvent('devagents:layout-changed', { detail: id }));
}

let layoutListening = false;

/** Aplica la disposición guardada y atiende las peticiones de Apariencia. */
export function initLayout(): void {
  applyLayout(readLayout(), false);
  if (layoutListening) return;
  layoutListening = true;
  document.addEventListener('devagents:set-layout', (ev) => {
    const id = (ev as CustomEvent).detail;
    if (id !== 'A' && id !== 'B' && id !== 'C') return;
    applyLayout(id, true);
  });
}

const PANEL_LEFT_KEY = 'devagents.panel.left';
const PANEL_RIGHT_KEY = 'devagents.panel.right';

/** Recuerda la barra izquierda y la visibilidad de las ventanas flotantes.
 * r4-1: un solo control de ocultar ventanas — el primero de la fila de iconos
 * sobre las ventanas; la barra de título ya no lo repite. Los paneles
 * opcionales tienen un ciclo independiente y nunca se restauran abiertos al
 * arrancar. */
export function initPanelToggles(): () => void {
  const sidebar = document.getElementById('sidebar-primary');
  const btnLeft = document.getElementById('btn-sidebar-collapse');
  const panelRight = document.getElementById('right-cards-host');
  const btnRight = panelRight?.querySelector<HTMLElement>('[data-rc-action="panel"]');
  const readCollapsed = (key: string): boolean => {
    try {
      return localStorage.getItem(key) === 'true';
    } catch (error) {
      notice('No se pudo leer el estado de los paneles: ' + String(error), 'error');
      return false;
    }
  };
  const saveCollapsed = (key: string, collapsed: boolean): void => {
    try {
      localStorage.setItem(key, String(collapsed));
    } catch (error) {
      notice('No se pudo guardar el estado de los paneles: ' + String(error), 'error');
    }
  };

  const applyLeft = (collapsed: boolean): void => {
    if (sidebar) sidebar.dataset.collapsed = collapsed ? 'true' : 'false';
    if (btnLeft) {
      // (c): en B el botón vive en la cabecera de Sesiones con el
      // icono de panel lateral de la maqueta; en A, la flecha de siempre.
      const unified = document.documentElement.dataset.layout === 'B';
      if (unified) {
        // B (como Claude): mismo icono de panel lateral en los dos estados.
        btnLeft.innerHTML = icons.sidebarLeft(15);
        btnLeft.title = collapsed ? 'Mostrar barra lateral (Ctrl+B)' : 'Ocultar barra lateral (Ctrl+B)';
        btnLeft.setAttribute('aria-label', btnLeft.title);
        btnLeft.setAttribute('aria-expanded', String(!collapsed));
        btnLeft.setAttribute('aria-controls', 'sidebar-primary');
      } else {
        btnLeft.innerHTML = collapsed ? icons.chevronRight(16) : icons.chevronLeft(14);
        btnLeft.title = collapsed ? 'Desplegar barra lateral' : 'Plegar barra lateral';
        btnLeft.removeAttribute('aria-expanded');
      }
    }
  };

  const applyRight = (collapsed: boolean): void => {
    if (panelRight) panelRight.dataset.collapsed = collapsed ? 'true' : 'false';
    document.getElementById('central-container')?.classList.toggle('cards-hidden', collapsed);
    if (btnRight) {
      btnRight.innerHTML = icons.sidebarRight(16);
      btnRight.title = collapsed ? 'Mostrar ventanas' : 'Ocultar ventanas';
      btnRight.setAttribute('aria-label', btnRight.title);
      btnRight.setAttribute('aria-controls', 'right-cards-host');
      btnRight.setAttribute('aria-expanded', String(!collapsed));
    }
  };

  applyLeft(readCollapsed(PANEL_LEFT_KEY));
  document.addEventListener('devagents:layout-changed', () => applyLeft(sidebar?.dataset.collapsed === 'true'));
  applyRight(readCollapsed(PANEL_RIGHT_KEY));

  // (e), comportamiento de Claude en B: con la barra oculta (o la
  // ventana estrecha), pasar el ratón por el botón la muestra flotando y se
  // puede navegar; al alejarse desaparece; un clic la fija.
  const isB = (): boolean => document.documentElement.dataset.layout === 'B';
  const narrow = (): boolean => (document.documentElement.dataset.bp || '').split(/s+/).includes('860');
  let peekTimer = 0;
  const setPeek = (on: boolean): void => { sidebar?.classList.toggle('is-peek', on); };
  const showPeek = (): void => {
    if (!sidebar || !isB() || !(sidebar.dataset.collapsed === 'true' || narrow())) return;
    window.clearTimeout(peekTimer);
    setPeek(true);
  };
  const hidePeekSoon = (): void => {
    window.clearTimeout(peekTimer);
    peekTimer = window.setTimeout(() => setPeek(false), 250);
  };
  btnLeft?.addEventListener('mouseenter', showPeek);
  btnLeft?.addEventListener('mouseleave', hidePeekSoon);
  sidebar?.addEventListener('mouseenter', () => { if (sidebar.classList.contains('is-peek')) window.clearTimeout(peekTimer); });
  sidebar?.addEventListener('mouseleave', () => { if (sidebar.classList.contains('is-peek')) hidePeekSoon(); });
  btnLeft?.addEventListener('click', (event) => {
    window.clearTimeout(peekTimer);
    setPeek(false);
    // Ventana estrecha en B: no hay sitio para fijarla; el clic la muestra
    // flotando hasta el siguiente clic (o Escape).
    if (isB() && narrow()) {
      event.stopImmediatePropagation();
      sidebar?.classList.toggle('is-peek-pinned');
    }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && sidebar?.classList.contains('is-peek-pinned')) sidebar.classList.remove('is-peek-pinned');
    if ((event.ctrlKey || event.metaKey) && !event.shiftKey && !event.altKey && event.key.toLowerCase() === 'b') {
      event.preventDefault();
      btnLeft?.click();
    }
  });
  btnLeft?.addEventListener('click', () => {
    const collapsed = sidebar?.dataset.collapsed !== 'true';
    applyLeft(collapsed);
    saveCollapsed(PANEL_LEFT_KEY, collapsed);
  });
  // (c): en B plegada la barra lateral desaparece entera y el botón
  // de plegar con ella; «Desplegar panel» de la franja hace lo mismo que él.
  document.getElementById('act-expand')?.addEventListener('click', () => btnLeft?.click());

  const toggleRight = (): void => {
    if (!panelRight) return;
    const collapsed = panelRight?.dataset.collapsed !== 'true';
    applyRight(collapsed);
    saveCollapsed(PANEL_RIGHT_KEY, collapsed);
  };

  // r4-1: sin botón de título, el click del icono «panel» de la fila es el
  // trigger único (delegación del panel; main.ts lo conecta con
  // togglePanelLazy).
  return toggleRight;
}
