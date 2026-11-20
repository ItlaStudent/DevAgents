import { checkVersion } from './version_check';
import {
  renderLayout,
  initLayout,
  updateEngineStatus,
  initPanelToggles,
  updatePermissionBadge,
  ViewId,
} from './layout/layout';
import { BridgeClient } from './bridge/client';
import { CoreApi } from './bridge/core_api';
import { ViewRouter } from './app/view_router';
import { toggleTerminalPanel, toggleRightPanel } from './app/terminal_toggle';

import { ChatPanel } from './panes/chat_panel';
import { RightCardsPanel } from './panes/right_cards';
import { runnerFor } from './file_runtime';
import { MissionControlPanel } from './panes/mission_control';
import { confirmModal } from './design/modal';
import { initI18n, untranslated } from './i18n/i18n';
import { VerificationPanel } from './panes/verification_panel';
import { CatalogSessionsPanel } from './panes/catalog_sessions';
import { SpacesPanel } from './panes/SpacesPanel';
import { UnifiedSettingsPanel } from './panes/settings_memory';
import { McpPanel } from './panes/mcp_panel';
import { IssuesPanel } from './panes/issues_panel';
import { MonitorPanel } from './panes/monitor_panel';

import { MonacoEditor } from './editor/monaco_editor';
import { TabManager } from './layout/tab_manager';
import { DiffViewer } from './editor/diff_viewer';
import { CommandPalette } from './components/command_palette';

import { injectStylesheet } from './design/stylesheet';
import { notice } from './design/notice';
import { statusLabel } from './design/status_labels';
import { ThemeManager } from './design/theme_registry';
import { matrixGreenTheme, registerMatrixGreenTheme } from './design/theme_matrix_green';
import { ConversationControl } from './components/conversation_control';
import { HelpPanel, OnboardingModal } from './components/onboarding_help';
import { installCopyImageMenu } from './components/copy_image_menu';
import { UiActionDispatcher } from './ui_actions';
import { mountSecondaryView, mountSecondaryFallback, parseWindowQuery, secondaryMountPlan } from './window_mode';
import { installPickedElementReceiver, openPreviewArtifact } from './preview_elements';
import { BrowserBar } from './browser/browser_bar';
import { AttentionCenter, AttentionTray } from './components/attention';
import { CliQuotaStatus } from './components/cli_quota';
import { UpdateController, sharedUpdateController } from './components/update_view';
import { raiseAlert, clearAlert } from './design/alerts';
import { showBootSplash, hideBootSplash } from './design/boot_splash';
import { installKeybindings, registerBindableCommands } from './app/keybindings';

// E2.16 — bitácora de errores de la cabina en memoria (anillo de 200). El
// botón de diagnóstico del panel de ayuda la adjunta al informe; sin ella el
// diagnóstico no tendría los fallos de consola que el usuario ya no ve.
const DEVAGENTS_LOG_CAP = 200;
(window as any).__devagentsLog = (window as any).__devagentsLog || [];
const pushDevLog = (level: string, args: unknown[]) => {
  const log = (window as any).__devagentsLog as Array<{ ts: string; level: string; text: string }>;
  try {
    log.push({
      ts: new Date().toISOString(),
      level,
      text: args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ').slice(0, 2000),
    });
    if (log.length > DEVAGENTS_LOG_CAP) log.splice(0, log.length - DEVAGENTS_LOG_CAP);
  } catch {
    /* el log nunca rompe la consola que envuelve */
  }
};
for (const level of ['error', 'warn'] as const) {
  const orig = console[level].bind(console);
  console[level] = ((...args: unknown[]) => {
    pushDevLog(level, args);
    orig(...args);
  }) as typeof console[typeof level];
}
window.addEventListener('error', (e) => pushDevLog('uncaught', [e.message, e.filename, e.lineno]));
window.addEventListener('unhandledrejection', (e) => pushDevLog('unhandledrejection', [String(e.reason)]));

document.addEventListener('DOMContentLoaded', async () => {
  // 1. Estilos y tema ANTES de pintar: evita el parpadeo de colores por defecto.
  injectStylesheet();
  // Maqueta v2, pág. 4: solo el icono aprobado mientras el motor se prepara.
  showBootSplash();
  // 22-09: sin foco o sin visibilidad, la cabina no anima nada (la regla CSS
  // .app-inactiva pausa los pulsos del fondo). Así, con DevAgents detrás de un
  // juego o de otra aplicación, no compite por la GPU.
  const marcarActividad = (): void => {
    document.documentElement.classList.toggle('app-inactiva', document.hidden || !document.hasFocus());
  };
  window.addEventListener('focus', marcarActividad);
  window.addEventListener('blur', marcarActividad);
  document.addEventListener('visibilitychange', marcarActividad);
  marcarActividad();

  const themeManager = new ThemeManager();
  registerMatrixGreenTheme(themeManager);
  themeManager.applyTheme(themeManager.getCurrentThemeId());
  (window as any).themeManager = themeManager;
  void matrixGreenTheme;

  // 2. Puente con el host C++ y API tipada del motor.
  const bridgeClient = new BridgeClient();
  const core = new CoreApi(bridgeClient);
  if (!await checkVersion(core)) { hideBootSplash(); return; }
  (window as any).bridgeClient = bridgeClient;
  (window as any).core = core;

  renderLayout(document.body);
  // (c): B · Unificada por defecto, A elegible en Apariencia.
  initLayout();
  const quotaHost = document.querySelector<HTMLElement>('.status-bar__group');
  if (quotaHost) {
    const quotaStatus = new CliQuotaStatus(core, quotaHost);
    quotaStatus.start();
    window.addEventListener('pagehide', () => quotaStatus.stop(), { once: true });
  }

  // Barra del navegador integrado: la pinta esta WebUI de confianza; el host
  // solo aloja la página debajo (sin puente). Ver src/browser/browser_bar.ts.
  function toggleBrowser(): void {
    void bridgeClient
      .send('browser.panel.toggle', { order_id: missionControl?.getActiveOrderId() ?? 0 })
      .catch((error) => notice(String(error), 'error'));
  }
  // 10-nov: abre (sin cerrar nunca) y engancha el navegador a la orden cuyo
  // agente lo pide. Una vez por orden basta: el host ignora repeticiones.
  let browserEnsuredFor = 0;
  function ensureBrowserFor(orderId: number): void {
    if (orderId <= 0 || browserEnsuredFor === orderId) return;
    browserEnsuredFor = orderId;
    void bridgeClient
      .send('browser.panel.toggle', { order_id: orderId, ensure: true })
      .catch((error) => {
        browserEnsuredFor = 0;
        notice(`El agente pidió el navegador y no se pudo abrir: ${String(error)}`, 'error');
      });
  }
  const browserBar = new BrowserBar(bridgeClient, toggleBrowser);
  void browserBar.start();

  // La Terminal se solicita desde la fila superior; cerrar no mata su PTY.
  const toggleTerminalView = toggleTerminalPanel;

  // 3. Editor, pestañas y paleta de comandos.
  const tabManager = new TabManager(document.getElementById('tab-bar') || undefined);
  const editorHost = document.getElementById('monaco-editor-container');
  const primaryEditor = editorHost ? new MonacoEditor(editorHost, bridgeClient) : null;
  let activeEditor = primaryEditor;
  if (primaryEditor) primaryEditor.onFocus = (editor) => {
    activeEditor = editor;
    tabManager.focusPath(editor.getFilePath());
  };
  const commandPalette = new CommandPalette();
  const helpPanel = new HelpPanel();
  // (c): la ayuda deja de vivir solo en la paleta: franja de
  // iconos (las dos disposiciones) y pie del panel en B. (Configuración del
  // pie lo cablea el router: es navegación.)
  document.getElementById('act-help')?.addEventListener('click', (e) => helpPanel.show(e.currentTarget as HTMLElement));
  // Configuración › Acerca de y ayuda pide la ayuda con un evento (no importa main).
  document.addEventListener('devagents:open-help', (e) => helpPanel.show(((e as CustomEvent).detail as HTMLElement | undefined) ?? null));
  document.getElementById('sb-foot-help')?.addEventListener('click', (e) => helpPanel.show(e.currentTarget as HTMLElement));
  const onboarding = new OnboardingModal();
  window.addEventListener('devagents:show-onboarding', () => onboarding.show());
  // E5.22 — la query la pone el host al crear la ventana (?ventana=&vista=).
  // Se lee una vez y manda sobre todo el arranque: una secundaria no muestra
  // onboarding ni sondea acciones de UI (dos ventanas ackeando lo mismo es
  // una carrera — el sondeo queda solo en la principal).
  const winQuery = parseWindowQuery(window.location.search);
  // (b): como en las IDE de referencia, el tutorial es del PRIMER
  // arranque: lo decide el motor (ya visto, o ya hay claves, órdenes o una CLI
  // con sesión en la última detección guardada). Si
  // hay uso previo se marca como visto sin enseñarlo. Mientras el motor
  // arranca se reintenta; si no responde, manda el espejo local de siempre.
  if (!winQuery) {
    const decideOnboarding = async (attempt: number): Promise<void> => {
      try {
        const state = await core.onboardingState();
        if (state.done) return;
        if (state.has_usage) {
          localStorage.setItem('devagents.onboarded', '1');
          await core.onboardingDone();
          return;
        }
        onboarding.show();
      } catch (e) {
        if (attempt < 10) {
          window.setTimeout(() => void decideOnboarding(attempt + 1), 1500);
          return;
        }
        console.warn('El motor no dijo si el tutorial ya se vio; se usa el espejo local:', e);
        if (!localStorage.getItem('devagents.onboarded')) onboarding.show();
      }
    };
    void decideOnboarding(0);
  }
  // Tanda 5 (F0.4): actualizador. Un controlador por ventana (Ajustes lo
  // reutiliza). La comprobación diaria la pide solo la principal, con la
  // cabina ya pintada; va al carril lento del host y el motor respeta las
  // 24 h. Cualquier cambio (comprobación, descarga, ajuste) llega a todas las
  // ventanas como difusión `update.changed`.
  const updates = sharedUpdateController(() => new UpdateController(core, { raise: raiseAlert, clear: clearAlert }))!;
  bridgeClient.onPush((topic) => {
    if (topic === 'update.changed') void updates.refresh();
  });
  if (!winQuery) void updates.startup();
  else void updates.refresh();
  const conversationControl = new ConversationControl(bridgeClient);

  // Abrir un archivo es abrir (o reactivar) su pestaña: la selección de
  // pestaña es la única que muestra el editor y carga el contenido. Antes esto
  // lo hacía por su cuenta y además la selección lo repetía (dos doc.open).
  const openFile = (path: string, name: string) => {
    tabManager.openTab(path, name);
  };

  // Se declara aquí porque la invocan tres sitios: el botón de la barra de
  // pestañas, el "+" de la lista de sesiones y el botón dentro del hilo.
  const newConversation = () => {
    if (!missionControl?.canStartNewConversation()) {
      notice('La orden actual sigue abierta. Termínala o descarta el plan antes de iniciar otro chat.', 'info');
      return;
    }
    router.show('agent');
    missionControl?.newConversation();
    chatPanel?.clear();
  };

  // Sin esto, abrir varias pestañas funcionaba pero pulsar una no cargaba su
  // archivo: el editor se quedaba con el contenido de la anterior.
  //
  // 22-09: y además tiene que TRAER el editor al frente. Desde la vista de
  // agente (o tras pulsar Dev, que solo cambia la barra lateral) la pestaña
  // cargaba su archivo en un editor oculto y, para el usuario, pulsarla no
  // hacía nada: solo se llegaba al archivo buscándolo en el explorador.
  // `showEditor` en vez de `show('explorer')`: navegar por el árbol no cambia
  // el área central; abrir o elegir un archivo sí.
  tabManager.onTabSelect((tab) => {
    router.showEditor();
    activeEditor?.openFile(tab.path);
  });

  // Cerrar la pestaña olvida su borrador y su posición: al reabrirla se lee el
  // disco, que es lo que el usuario espera después de cerrar algo.
  tabManager.onTabClose((tab) => {
    activeEditor?.forgetFile(tab.path);
  });

  const openSession = async (orderId: number, conversationId?: string | null) => {
    if (missionControl?.isBusy()) {
      notice('La orden actual sigue en curso. Espera a que termine antes de abrir otra sesión.', 'info');
      return;
    }
    router.show('agent');
    chatPanel?.clear();
    chatPanel?.setStatus(`Sesión #${orderId}`, 'idle');
    await missionControl?.loadSession(orderId, conversationId || undefined);
  };

  // 4. Enrutador de vistas: barra de actividad, barra lateral y panel inferior.
  const router = new ViewRouter(core, {
    onOpenFile: openFile,
    hasUnsavedChanges: (path) => primaryEditor?.isDirty(path) ?? false,
    onFilesReplaced: async (paths) => {
      for (const path of paths) await primaryEditor?.reloadSavedFile(path);
    },
    // El host solo admite http(s) o rutas locales absolutas; ver shell.open.
    onOpenExternal: (url) => void bridgeClient.send('shell.open', { target: url }),
    onNewConversation: () => newConversation(),
    onOpenSession: openSession,
  });

  // UI-ACTION: dispatcher de acciones cosméticas pedidas por agentes/órdenes.
  // Las acciones por-orden llegan vía drainNewEvents (hook onUiAction); este
  // sondeo cubre las globales (order_id=0) que escribe cualquier cliente MCP.
  const uiActions = new UiActionDispatcher(core, {
    applyTheme: (themeId) => themeManager.applyTheme(themeId),
    hasTheme: (themeId) => themeManager.getAvailableThemes().some((t) => t.id === themeId),
    showView: (view) => router.show(view as ViewId),
    focusSession: (sessionId) => void openSession(Number(sessionId)),
    // T8: el agente pide ver el grafo de su orden. Solo vista.
    showOrderGraph: () => {
      router.show('agent');
      missionControl?.showOrderGraph();
    },
    // E5.21: accion open_window → ventana secundaria nativa (host la valida
    // con ParseOpenWindow; aqui solo se traduce el contrato del puente).
    openWindow: (req) =>
      bridgeClient.send<typeof req, { window_id?: number }>('window.open', req),
  });
  if (!winQuery) uiActions.start();

  // 5. Paneles.
  // Se declara antes del centro de mando: su onActivity reenvía los eventos
  // file_written a las tarjetas del panel derecho (abajo se construyen).
  let rightCards: RightCardsPanel | null = null;
  const missionEl = document.getElementById('pane-mission-container');
  const missionControl = missionEl
    ? new MissionControlPanel(missionEl, core, {
        onRequestSettings: () => router.show('settings'),
        onRequestDevMode: () => router.show('explorer'),
        onActivity: (kind, data) => {
          if (kind === 'status') {
            // Una sola etiqueta para todas las fases (P1): sin esto la cabecera
            // del panel de ACTIVIDAD enseñaba `awaiting-approval`, `error`…
            chatPanel?.setStatus?.(statusLabel(String(data)), data === 'running' ? 'working' : 'idle');
            // Sin esto, la tarjeta de plan del panel derecho seguía diciendo
            // "pendiente de aprobar" con la orden ya ejecutada.
            chatPanel?.setPhase?.(String(data));
            // La orden nace (plan, pregunta o charla), cambia de fase o termina:
            // la barra de sesiones tiene que enterarse sin pulsar «Actualizar».
            if (['planning', 'running', 'best-of-n', 'awaiting-approval', 'clarifying', 'chat', 'done', 'interrupted', 'audit-unavailable', 'error'].includes(String(data))) {
              router.refreshSessions();
            }
          }
          if (kind === 'events') {
            chatPanel?.appendEvents?.(data as never);
            rightCards?.appendEvents(data as never);
            router.observeOrderEvents(data as never);
          }
          if (kind === 'plan') chatPanel?.setPlan?.(data);
        },
        onUiAction: (eventId, payload) => void uiActions.handleOrderEvent(eventId, payload as never),
        onBrowserNeeded: (orderId) => ensureBrowserFor(orderId),
      })
    : null;

  // r3: ventanas dentro del area del chat y Actividad en el dock
  // opcional. El controlador de visibilidad se instala tras pintar los iconos.
  let togglePanelLazy: () => void = () => undefined;
  const rightHost = document.getElementById('right-cards-host');
  rightCards = rightHost
    ? new RightCardsPanel(rightHost, core, {
        onEnvironment: (project, root) => {
          const title = document.getElementById('project-name');
          if (title) { title.textContent = project || '—'; title.title = root; }
        },
        changeWorkspace: () => void changeWorkspaceRoot(),
        togglePanel: () => togglePanelLazy(),
        toggleTerminal: () => toggleTerminalView(),
        toggleBrowser,
        toggleActivity: () => toggleRightPanel('activity'),
        showExplorer: () => toggleRightPanel('explorer'),
        showMenu: () => commandPalette.show(),
        activeOrderId: () => missionControl?.getActiveOrderId() ?? 0,
      })
    : null;
  const chatHost = document.getElementById('chat-host');
  const chatPanel = chatHost ? new ChatPanel(chatHost, conversationControl) : null;
  document.getElementById('chat-btn-collapse')?.addEventListener('click', () => router.closeSidePanel());
  // La Terminal ya no esta acoplada: su icono la abre y la cierra, y el icono
  // refleja si el panel esta a la vista.
  const bottomPanel = document.getElementById('panel-bottom');
  if (bottomPanel && rightCards) {
    const syncTerminalIcon = (): void => {
      const dock = document.getElementById('panel-secondary');
      rightCards?.setTerminalVisible(dock?.dataset.collapsed === 'false' && dock.dataset.panel === 'terminal');
    };
    new MutationObserver(syncTerminalIcon).observe(bottomPanel, {
      attributes: true,
      attributeFilter: ['data-collapsed'],
    });
    syncTerminalIcon();
  }
  // E2.17 — el menú «Copiar imagen» también aplica al transcript central, no
  // solo a las tarjetas del panel ACTIVIDAD (medido en vivo 2026-09-18: el
  // clic derecho sobre un turno del chat no abría nada).
  if (chatHost) installCopyImageMenu(chatHost);

  const settingsEl = document.getElementById('pane-settings-container');
  const settingsPanel = settingsEl ? new UnifiedSettingsPanel(settingsEl, core) : null;

  const mcpEl = document.getElementById('pane-mcp-container');
  const mcpPanel = mcpEl ? new McpPanel(mcpEl, core) : null;
  const issuesEl = document.getElementById('pane-issues-container');
  const issuesPanel = issuesEl ? new IssuesPanel(issuesEl, core, (request, prompt) => {
    if (!missionControl) throw new Error('El compositor no está disponible.');
    missionControl.importIssue(request, prompt);
    router.show('agent');
  }) : null;

  const monitorEl = document.getElementById('pane-monitor-container');
  const monitorPanel = monitorEl ? new MonitorPanel(monitorEl, core, bridgeClient) : null;

  const verificationEl = document.getElementById('pane-verification-container');
  const verificationPanel = verificationEl ? new VerificationPanel(verificationEl) : null;

  const catalogEl = document.getElementById('pane-catalog-container');
  const catalogPanel = catalogEl ? new CatalogSessionsPanel(catalogEl) : null;
  catalogPanel?.setOnReplaySession((id, conversationId) => {
    const orderId = Number(id);
    if (orderId) void openSession(orderId, conversationId);
  });

  // PRUEBA DE USUARIO 31-08 (paneles vacíos): el panel del catálogo estaba
  // INSTANCIADO pero NADIE lo alimentaba — setCatalog/setSessions solo los
  // llamaban los tests. El usuario que abría "Spaces y sesiones" veía un
  // panel vacío para siempre. Se conecta aquí: catálogo desde la tabla que
  // expone el motor (core.models.list) y sesiones desde core.sessions.list.
  if (catalogPanel) {
    const refreshCatalogPanel = async () => {
      try {
        // BridgeClient resuelve con el mensaje COMPLETO {id,status,payload}:
        // el desempaquetado del payload es aquí (lo aprendí porque el catch
        // silencioso dejaba el panel vacío sin rastro en consola).
        const res = (await bridgeClient.send<unknown, { payload?: string }>(
          'core.models.list',
          {}
        )) as { payload?: string };
        const text = typeof res?.payload === 'string' ? res.payload : String(res ?? '');
        // El motor expone una tabla markdown (listModels). Filas de
        // "prov | model | ctx | free | avail | fav" con cabecera y separador.
        const rows = text
          .split('\n')
          .filter((l) => l.includes('|') && !l.startsWith('---') && !l.startsWith('Provider |'));
        const models = rows
          .map((line) => line.split('|').map((c) => c.trim()))
          .filter((c) => c.length >= 6)
          .map((c) => ({
            id: `${c[0]}/${c[1]}`,
            provider: c[0],
            name: c[1],
            isFree: c[3] === 'yes',
            contextWindow: Number(c[2]) || 0,
            latencyMs: 0,
          }));
        catalogPanel.setCatalog(models);
      } catch (err) {
        // Sin catálogo el panel queda como estaba; el error se deja en
        // consola para que la próxima sesión de prueba lo vea.
        console.error('[catalogPanel] core.models.list falló:', err);
      }
      try {
        const sessions = (await core.listSessions()) as Array<{
          id?: number;
          title?: string;
          message_count?: number;
          conversation_id?: string | null;
        }>;
        catalogPanel.setSessions(
          (sessions || []).slice(0, 100).map((s) => ({
            id: String(s.id ?? ''),
            title: s.title || `Orden ${s.id ?? ''}`,
            messageCount: s.message_count ?? 0,
            updatedAt: '',
            conversationId: s.conversation_id ?? null,
          }))
        );
      } catch (err) {
        console.error('[catalogPanel] core.sessions.list falló:', err);
      }
    };
    void refreshCatalogPanel();
    // 9-nov: Spaces vive en esta vista (ya no es sección del panel izquierdo).
    // Se monta al entrar, así la lista llega siempre al día.
    let spacesView: SpacesPanel | null = null;
    const mountSpaces = (): void => {
      const host = catalogPanel.spacesHost();
      if (!host) return;
      spacesView?.detach();
      spacesView = new SpacesPanel(host, core);
    };
    // Y en cada retorno a la vista, porque el usuario espera ver los cambios.
    document.addEventListener('devagents:view-changed', (e) => {
      const view = (e as CustomEvent).detail as string;
      if (view === 'spaces') {
        void refreshCatalogPanel();
        mountSpaces();
      }
    });
  }

  // El visor de diff vivía en un div suelto que nunca se insertaba en el DOM:
  // el HunkManager del host, completo y con tests, no tenía ninguna interfaz.
  const diffEl = document.getElementById('pane-diff-container');
  const diffViewer = diffEl ? new DiffViewer(diffEl, core) : null;

  /**
   * Revisa lo editado en el buffer contra lo que hay en disco, y deja aceptar
   * o rechazar cada bloque por separado antes de escribir. Es el mismo
   * componente que reutilizará el flujo de cambios propuestos por el agente.
   */
  const reviewCurrentFile = async () => {
    if (!diffViewer || !activeEditor) return;
    const path = activeEditor.getFilePath();
    if (!path) {
      router.show('explorer');
      return;
    }
    router.show('diff');
    await diffViewer.showDiff(path, activeEditor.getValue());
  };

  /**
   * Cambia la carpeta sobre la que trabaja el agente.
   *
   * `core.workspace.set` existía en el puente y `setWorkspace` en la API, pero
   * no había un solo llamador: la raíz solo se podía cambiar reiniciando la
   * aplicación desde otro directorio. Se pide con el diálogo del sistema, no
   * escribiendo la ruta, y se refresca el explorador para que lo que se ve
   * corresponda con lo que el agente puede tocar.
   */
  const changeWorkspaceRoot = async () => {
    try {
      // El diálogo nativo autoriza y cambia la carpeta en una sola operación.
      // El cambio re-ancla la raíz EN CALIENTE y hasta hace poco lo hacía
      // en silencio total. Con una orden en vuelo el usuario debe saber que la
      // orden sigue atada a SU raíz original (order_root override) y que la
      // nueva carpeta manda sobre las siguientes — se avisa, no se rechaza:
      // cambiar de carpeta es legítimo a mitad de trabajo.
      if (missionControl?.isBusy()) {
        const ok = await confirmModal({
          title: 'Hay una orden en curso',
          paragraphs: [
            'Seguirá trabajando sobre su carpeta original; la nueva carpeta aplicará ' +
              'a las órdenes siguientes.',
          ],
          confirmLabel: 'Cambiar carpeta',
        });
        if (!ok) return;
      }
      const picked = await core.pickWorkspace();
      if (picked.cancelled || !picked.path) return;
      // r2: Entorno, Cambios y Resultados releen el proyecto nuevo.
      document.dispatchEvent(new CustomEvent('devagents:workspace-changed'));
      notice(
        'Carpeta de trabajo del agente:\n' + picked.path +
          (missionControl?.isBusy() ? '\n(la orden en curso conserva su raíz original)' : ''),
        'ok',
        6000
      );
      router.show('explorer');
    } catch (e) {
      notice('No se pudo cambiar la carpeta de trabajo: ' + String(e), 'error');
    }
  };

  /**
   * Autocompletado por comentario, al estilo del de Colab.
   *
   * Escribes una intención como comentario en la línea del cursor y pulsas
   * Ctrl+Enter: se manda el archivo entero más esa instrucción al modelo, y lo
   * que devuelve NO se inserta — se abre en el visor por bloques, con Aceptar y
   * Rechazar. Reaprovecha entero el ciclo de revisión que ya existía.
   */
  const completeFromComment = async () => {
    if (!activeEditor || !diffViewer) return;
    const path = activeEditor.getFilePath();
    if (!path) return;

    const full = activeEditor.getValue();
    const lines = full.split('\n');
    // La instrucción es el último comentario por encima del cursor. Se buscan
    // las marcas de las tres familias que maneja el proyecto.
    // Sin `findLast`: el target de TypeScript del proyecto es anterior a ES2023
    // y no conviene subirlo por una sola llamada.
    let line = '';
    for (const l of lines) {
      if (/^\s*(#|\/\/|--)\s*\S/.test(l)) line = l;
    }
    const intent = line.replace(/^\s*(#|\/\/|--)\s*/, '').trim();
    if (!intent) {
      commandPalette.show();
      return;
    }

    const system =
      'Eres un asistente de programación. Devuelves SIEMPRE el contenido ' +
      'completo del archivo con el cambio aplicado, y NADA más: sin ' +
      'explicaciones, sin comentarios sobre lo que hiciste y sin vallas de ' +
      'código. La primera línea de tu respuesta es la primera línea del archivo.';
    const prompt =
      `Cambio pedido: ${intent}\n\n--- Archivo actual (${path}) ---\n${full}`;

    const cerrar = notice('Pidiendo la propuesta al modelo…', 'info', 0);
    try {
      // Llamada DIRECTA al modelo, no `submitOrder`.
      //
      // Antes esto iba por el planificador, que no genera código: clasifica la
      // intención y devuelve un plan con una descripción en prosa en
      // `understanding`. Esa prosa es lo que acababa en el visor de cambios, y
      // por eso el flujo era inservible por muy afinado que estuviera el
      // prompt. La decisión D4 es que Ctrl+Enter no es una orden que planificar
      // sino una transformación de un solo disparo.
      // Plazo del lado de la interfaz.
      //
      // MITIGACIÓN, no la corrección de fondo: el cliente HTTP del motor no
      // tiene plazos (bug B4), así que una llamada puede no volver nunca. Sin
      // esto, el aviso «Pidiendo la propuesta…» se queda en pantalla para
      // siempre y Ctrl+Enter parece colgado — medido en vivo: 85 s sin
      // resolver. Esto NO cancela la llamada del motor, que sigue en curso;
      // solo devuelve el control al usuario. El arreglo real es meter
      // SO_RCVTIMEO en providers/src/http/client.zig.
      const PLAZO_MS = 90_000;
      const r = await Promise.race([
        core.completeText(prompt, system),
        new Promise<never>((_, rechazar) =>
          setTimeout(
            () =>
              rechazar(
                new Error(
                  `el modelo no respondió en ${PLAZO_MS / 1000} s. ` +
                    'Prueba con otro modelo desde el selector del compositor.'
                )
              ),
            PLAZO_MS
          )
        ),
      ]);
      cerrar();
      if (!r?.ok || !r.text) {
        notice('No se pudo completar: ' + (r?.error || 'el modelo no devolvió texto'), 'error');
        return;
      }

      // Algunos modelos envuelven en vallas de código pese a pedirles que no.
      // Quitarlas aquí es más barato y más fiable que insistir en el prompt.
      let proposed = r.text.trim();
      const valla = proposed.match(/^```[a-zA-Z0-9_+-]*\n([\s\S]*?)\n?```$/);
      if (valla) proposed = valla[1];
      if (!proposed.trim()) {
        notice('El modelo devolvió una respuesta vacía.', 'error');
        return;
      }

      router.show('diff');
      await diffViewer.showDiff(path, proposed);
      notice(`Propuesta de ${r.provider}/${r.model}. Acepta o rechaza por bloques.`, 'ok', 6000);
    } catch (e) {
      cerrar();
      notice('Autocompletar falló: ' + String(e), 'error');
    }
  };

  // Con Monaco real el Ctrl+Enter no llega al listener global (el editor lo
  // liga a InsertLineBelow) — el editor lo intercepta en captura y llama aquí.
  if (activeEditor) activeEditor.onCtrlEnter = () => void completeFromComment();

  // — Canvas y Diff de la cabecera del editor (en gris sin archivo).
  // Canvas abre/oculta el navegador integrado; Diff es la revisión por bloques.
  if (activeEditor) {
    activeEditor.onOpenCanvas = () => toggleBrowser();
    activeEditor.onReviewDiff = () => void reviewCurrentFile();
  }

  diffViewer?.setOnResolved((path, accepted, rejected) => {
    console.log(`[DevAgents] ${path}: ${accepted} bloques aceptados, ${rejected} rechazados`);
    // Tras resolver, el editor recarga desde disco para reflejar lo aplicado.
    void activeEditor?.openFile(path);
  });

  Object.assign(window as any, {
    tabManager,
    activeEditor,
    commandPalette,
    helpPanel,
    missionControl,
    chatPanel,
    rightCards,
    settingsPanel,
    mcpPanel,
    issuesPanel,
    monitorPanel,
    verificationPanel,
    catalogPanel,
    diffViewer,
    router,
  });

  // El Monitor solo se auto-refresca mientras está a la vista: sondear el
  // motor cada 5 s en segundo plano no aporta nada y compite con la orden.
  document.addEventListener('devagents:view-changed', (e) => {
    const view = (e as CustomEvent).detail as string;
    // Al volver al Agente se releen proveedores, claves y modelos.
    //
    // El selector de modelo del compositor se rellenaba UNA VEZ, al construir
    // el panel. Si añadías una clave en Configuración y volvías al chat, la
    // lista seguía mostrando el catálogo viejo — los modelos nuevos no
    // aparecían hasta crear una conversación nueva, que era lo único que
    // reconstruía el panel. Reportado por el usuario tras dar de alta Gemini y
    // Cohere.
    if (view === 'agent') void missionControl?.refreshStatus();
    if (view === 'monitor') {
      void monitorPanel?.refresh();
      monitorPanel?.startAutoRefresh(5000);
    } else {
      monitorPanel?.stopAutoRefresh();
    }
  });

  // Ya no hay dos compositores: el panel de actividad es de SOLO LECTURA y el
  // único sitio donde se escribe es el compositor central.

  // Panel de Cambios: pulsar un archivo lo abre en el editor, y el botón de
  // ejecutar lo lanza en la terminal integrada. Ese detalle no es cosmético —
  // la terminal vive FUERA del executor del motor, así que un programa con
  // ventana (un reloj, un servidor) sigue vivo cuando la orden termina, cosa
  // que no ocurre si lo lanza el agente.
  document.addEventListener('devagents:open-file', (e) => {
    const path = String((e as CustomEvent).detail || '');
    if (!path) return;
    openFile(path, path.split(/[\\/]/).pop() || path);
  });

  // E5.25: la raíz procede del motor. El puente recibe solo una ruta HTML
  // relativa y el host la vuelve a confinar antes de abrir la vista aislada.
  document.addEventListener('devagents:preview-artifact', (e) => {
    const path = (e as CustomEvent).detail?.path;
    if (typeof path !== 'string' || !path) return;
    const orderId = missionControl?.getActiveOrderId() ?? 0;
    void openPreviewArtifact(orderId, path, core, bridgeClient)
      .catch((error) => notice(`No se pudo abrir la vista previa: ${String(error)}`, 'error'));
  });

  if (missionControl) {
    installPickedElementReceiver(bridgeClient, {
      primary: !winQuery,
      showComposer: () => router.show('agent'),
      attach: (file, context) => missionControl.attachPickedElement(file, context),
      report: (message) => notice(message, 'error'),
    });
  }

  document.addEventListener('devagents:run-file', async (e) => {
    const detail = (e as CustomEvent).detail;
    const request = detail && typeof detail === 'object' ? detail as { path?: unknown; runner?: unknown; report?: (error: string) => void } : null;
    const path = String(request?.path ?? (typeof detail === 'string' ? detail : ''));
    if (!path) return;
    const name = path.split(/[\\/]/).pop() || path;
    const expectedRunner = runnerFor(name);
    const javascript = /\.(?:js|mjs)$/i.test(name);
    // Los paneles de artefactos deben entregar su clasificación junto con la
    // ruta. Un evento heredado de texto no puede convertir un .js ambiguo en
    // Node; los comandos escritos manualmente siguen usando la terminal
    // directamente y no pasan por este evento UI.
    if (javascript && request?.runner !== 'node') return;
    const runner = request ? String(request.runner ?? '') : expectedRunner;
    if (runner !== expectedRunner || expectedRunner === null) return;
    // `start` deja la ventana viva y devuelve el prompt en el acto; sin él, una
    // aplicación gráfica dejaría la terminal bloqueada hasta que se cierre.
    const dir = path.slice(0, path.length - name.length).replace(/[\\/]$/, '');
    // El titulo vacio NO es decorativo: `start "x.bat"` interpreta el primer
    // entrecomillado como TITULO DE VENTANA, no como archivo. Con .bat y .cmd
    // (donde `runnerFor` devuelve cadena vacia, no null) salia `start  "x.bat"`
    // y se abria una consola titulada con el nombre del script, sin ejecutarlo.
    const cmd = `start "" ${runner} "${name}"`.trim();
    const report = request?.report ?? ((error: string) => { if (error) notice(error, 'error'); });
    report('');
    try {
      if (/["%!\r\n]/.test(path)) throw new Error('La ruta contiene caracteres que la terminal puede interpretar.');
      const directory = await core.listDir(dir);
      if (!directory.entries.some(entry => entry.name.toLowerCase() === name.toLowerCase() && !entry.isDir)) {
        throw new Error('El archivo ya no está en la carpeta autorizada.');
      }
      if (!await router.runInTerminal(dir ? `cd /d "${dir}" && ${cmd}` : cmd)) {
        throw new Error('La terminal integrada no aceptó el comando.');
      }
    } catch (error) {
      report('No se pudo ejecutar el archivo. ' + String(error instanceof Error ? error.message : error));
    }
  });

  // E2.6 — «Ejecutar esto» desde un bloque de comando del chat: lo que se ve
  // en el bloque es lo que llega a la terminal, línea a línea.
  document.addEventListener('devagents:run-command', (e) => {
    const command = String((e as CustomEvent).detail || '');
    if (command.trim()) void router.runInTerminal(command);
  });

  // E2.11 — «Fork» de una sesión: abre una conversación NUEVA que hereda el
  // contexto de la anterior (sus mensajes viajan como adjunto de contexto).
  // Así se ramifica el trabajo sin reescribir ni repetir lo ya pedido.
  document.addEventListener('devagents:fork-session', (e) => {
    const orderId = Number((e as CustomEvent).detail || 0);
    if (orderId) void missionControl?.forkSession(orderId);
  });

  // La barra lateral de Configuración selecciona sección en el panel central.
  document.addEventListener('devagents:settings-section', (e) => {
    const section = (e as CustomEvent).detail as string;
    router.show('settings');
    settingsPanel?.showSection?.(section);
  });

  // 11-nov: idioma guardado (español por defecto; inglés desde Apariencia).
  try { initI18n(); } catch { /* sin traducción, la cabina sigue en español */ }
  // F1.11: diagnóstico — textos vistos sin traducción (para completar en.ts).
  (window as any).__devagentsI18nMissing = () => {
    try { return untranslated(); } catch { return []; }
  };

  // 6. Controles de ventana: los dibuja el WebUI, los ejecuta el host Win32.
  const winCmd = (command: string) => bridgeClient.send('window.command', { command }).catch(() => undefined);
  document.getElementById('btn-minimize')?.addEventListener('click', () => winCmd('minimize'));
  document.getElementById('btn-maximize')?.addEventListener('click', () => winCmd('maximize'));
  // QA primerizo (11-nov): cerrar no avisaba de lo que sigue en marcha. Las
  // órdenes, tareas y la terminal viven en un job del sistema que muere con la
  // ventana, así que se pregunta antes (como VS Code con sus terminales).
  document.getElementById('btn-close')?.addEventListener('click', async () => {
    const bg = rightCards?.backgroundSummary?.();
    const partes: string[] = [];
    if (bg?.orders) partes.push(bg.orders === 1 ? '1 orden en curso' : `${bg.orders} órdenes en curso`);
    if (bg?.tasks) partes.push(bg.tasks === 1 ? '1 tarea en segundo plano' : `${bg.tasks} tareas en segundo plano`);
    if (bg?.terminal) partes.push('la terminal y lo que esté ejecutando');
    if (partes.length) {
      const seguir = await confirmModal({
        title: '¿Cerrar DevAgents?',
        paragraphs: [`Se detendrá: ${partes.join(', ')}.`, 'Lo que ya está guardado no se pierde.'],
        confirmLabel: 'Cerrar de todos modos',
        cancelLabel: 'Seguir trabajando',
        danger: true,
      }).catch(() => true);
      if (!seguir) return;
    }
    void winCmd('close');
  });

  // Arrastre de la ventana. `-webkit-app-region: drag` es de Electron y en
  // WebView2 no hace nada: el WebView se queda con todos los eventos de ratón
  // y WM_NCHITTEST nunca llega a devolver HTCAPTION, por lo que la ventana no
  // se podía mover. Se avisa al host, que cede el arrastre al gestor de
  // ventanas (y con él, snap y movimiento entre monitores).
  const titlebar = document.querySelector<HTMLElement>('.titlebar');
  titlebar?.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    // Sobre un control interactivo manda el control, no el arrastre.
    if ((e.target as HTMLElement).closest('button, input, select, a')) return;
    void winCmd('drag');
  });
  titlebar?.addEventListener('dblclick', (e) => {
    if ((e.target as HTMLElement).closest('button, input, select, a')) return;
    void winCmd('maximize');
  });
  document.getElementById('btn-new-conversation')?.addEventListener('click', () => newConversation());
  document.getElementById('btn-settings')?.addEventListener('click', () => router.show('settings'));
  // 10-nov (propietario): atrás/avanzar entre vistas y «×» para salir de Configuración
  // volviendo a donde se estaba. La × se repinta con el panel: va delegada.
  document.getElementById('btn-nav-back')?.addEventListener('click', () => router.back());
  document.getElementById('btn-nav-forward')?.addEventListener('click', () => router.forward());
  document.addEventListener('click', (e) => {
    if ((e.target as HTMLElement | null)?.closest?.('#btn-settings-close')) router.closeSettings();
  });
  document.addEventListener('keydown', (e) => {
    const t = e.target as HTMLElement | null;
    const typing = !!t?.closest?.('input, textarea, select, [contenteditable="true"], .monaco-editor, .xterm');
    // Esc cierra Configuración si no hay un diálogo abierto encima.
    // Solo con el foco en la propia Configuración (o en ningún sitio): con un
    // diálogo o la paleta abiertos el foco está en ellos y Esc es suyo.
    const paletteOpen = (document.getElementById('command-palette-overlay')?.style.display ?? 'none') !== 'none';
    const inSettings = !t || t === document.body || !!t.closest?.('#pane-settings-container');
    if (e.key === 'Escape' && !typing && !paletteOpen && inSettings && document.documentElement.dataset.view === 'settings') {
      router.closeSettings();
    }
  });
  document.getElementById('btn-command-palette')?.addEventListener('click', () => commandPalette.show());

  // Plegado de las barras laterales: los botones de flecha viven en cada
  // cabecera y el estado persiste entre sesiones.
  const togglePanel = initPanelToggles();

  togglePanelLazy = togglePanel;

  // El indicador de permisos peligrosos tiene que estar puesto ANTES de que el
  // usuario abra Configuración: si dejó bypass activo en la sesión anterior,
  // debe verlo nada más arrancar, no la primera vez que entre al panel.
  try {
    const savedPerms = window.localStorage.getItem('devagents.permissions');
    if (savedPerms) updatePermissionBadge(String(JSON.parse(savedPerms)?.mode || 'normal'));
  } catch {
    // Espejo corrupto: no es motivo para romper el arranque.
  }

  // Los hooks se reaplican al arrancar por el mismo motivo que los permisos: el
  // motor no los guarda entre sesiones y no tiene getter, así que el espejo de
  // localStorage es la única fuente. Sin esto, un hook de bloqueo de rutas
  // dejaría de existir en silencio al reabrir la aplicación.
  try {
    const savedHooks = window.localStorage.getItem('devagents.hooks');
    if (savedHooks) void core.setHooks(JSON.parse(savedHooks)).catch(() => undefined);
  } catch {
    // Igual que arriba.
  }

  // Conmutador Agente/Dev de la barra de pestañas. Vive en el layout (no en el
  // centro de mando) para seguir visible al pasar al editor, que era justo
  // donde el usuario se quedaba sin forma de volver.
  const applyMode = (mode: 'agent' | 'dev') => {
    missionControl?.setMode(mode);
    document.getElementById('mode-agent')?.classList.toggle('is-active', mode === 'agent');
    document.getElementById('mode-dev')?.classList.toggle('is-active', mode === 'dev');
    router.show(mode === 'agent' ? 'agent' : 'explorer');
    // Dev con archivos abiertos vuelve al editor, en la pestaña activa. Sin
    // esto el centro seguía siendo la conversación y las pestañas quedaban
    // a la vista sin forma de llegar a su contenido.
    if (mode === 'dev' && tabManager.getActiveTab()) router.showEditor();
  };
  document.getElementById('mode-agent')?.addEventListener('click', () => applyMode('agent'));
  document.getElementById('mode-dev')?.addEventListener('click', () => applyMode('dev'));

  // Al navegar por la barra de actividad, el conmutador debe reflejar dónde
  // está el usuario en vez de quedarse desincronizado.
  document.addEventListener('devagents:view-changed', (e) => {
    const view = (e as CustomEvent).detail as string;
    const isAgent = view === 'agent';
    document.getElementById('mode-agent')?.classList.toggle('is-active', isAgent);
    document.getElementById('mode-dev')?.classList.toggle('is-active', view === 'explorer');
    missionControl?.setMode(isAgent ? 'agent' : 'dev');
  });

  document.getElementById('status-monitor')?.addEventListener('click', () => router.show('monitor'));

  // Open Design corre fuera de la cabina (WSL, Docker o un servicio web), igual
  // que en la versión con fork: aquí solo saltamos hacia él.
  const OPEN_DESIGN_URL = 'http://localhost:3000';
  document.getElementById('status-open-design')?.addEventListener('click', async () => {
    const el = document.getElementById('status-open-design');
    try {
      // Igual que hacía la versión con fork: no se enlaza a una URL, se ARRANCA
      // Open Design con Docker Compose en su carpeta de deploy y solo entonces
      // se abre. Si no está instalado, se dice qué falta en vez de abrir una
      // pestaña rota.
      if (el) el.textContent = 'Open Design: arrancando…';
      const res = (await bridgeClient.send('opendesign.launch', {})) as {
        payload?: { state?: string; url?: string; detail?: string };
      };
      const p = res?.payload || {};
      if (p.state === 'running' && p.url) {
        await bridgeClient.send('shell.open', { target: p.url });
        if (el) el.textContent = 'Open Design';
        return;
      }
      if (el) {
        el.textContent = p.state === 'not-installed' ? 'Open Design no instalado' : 'Open Design falló';
        el.title = String(p.detail || '');
        window.setTimeout(() => (el.textContent = 'Open Design'), 6000);
      }
      console.warn('[DevAgents] Open Design:', p.detail);
      return;
    } catch (err) {
      if (el) {
        el.textContent = 'Open Design no responde';
        window.setTimeout(() => (el.textContent = 'Open Design'), 3000);
      }
      console.warn('[DevAgents] Open Design:', err);
    }
  });
  const syncBudget = async () => {
    const el = document.getElementById('status-paid-budget');
    try {
      const budget = await core.getBudget();
      if (el) { el.textContent = `Pago: ${budget.remaining} restantes`; el.title = `${budget.spent} de ${budget.authorized} usadas. Autorizar más llamadas en Gobernanza`; }
      if (missionControl && !missionControl.isBusy()) {
        const check = await core.orderPreflight();
        missionControl.showConfiguration(check);
      }
    } catch (error) { if (el) { el.textContent = 'Pago: no disponible'; el.title = String(error); } }
  };
  document.getElementById('status-paid-budget')?.addEventListener('click', () => {
    document.dispatchEvent(new CustomEvent('devagents:settings-section', { detail: 'governance' }));
  });
  document.addEventListener('devagents:budget-changed', () => void syncBudget());
  void syncBudget();
  window.setInterval(syncBudget, 5000);
  document.getElementById('status-gov-mode')?.addEventListener('click', () => {
    router.show('settings');
    settingsPanel?.showSection?.('governance');
  });
  document.getElementById('status-model')?.addEventListener('click', () => {
    router.show('settings');
    settingsPanel?.showSection?.('models');
  });
  document.getElementById('status-key-label')?.addEventListener('click', () => {
    router.show('settings');
    settingsPanel?.showSection?.('providers');
  });

  // 7. Comandos de la paleta.
  let windowZoom = 100;
  // Configuración › Apariencia › Ventana cambia el zoom con este evento.
  document.addEventListener('devagents:zoom', (e) => changeWindowZoom((e as CustomEvent<number | null>).detail ?? null));
  const changeWindowZoom = (delta: number | null): void => {
    windowZoom = delta === null ? 100 : Math.max(50, Math.min(200, windowZoom + delta));
    document.documentElement.style.zoom = String(windowZoom / 100);
  };
  const saveAllFiles = async (): Promise<void> => {
    await activeEditor?.saveAllFiles();
    for (const tab of tabManager.getTabs()) tabManager.setDirty(tab.id, activeEditor?.isDirty(tab.path) ?? tab.isDirty);
  };
  const closeOtherTabs = (): void => {
    const active = tabManager.getActiveTab();
    if (!active) return;
    let preserved = 0;
    for (const tab of [...tabManager.getTabs()]) {
      if (tab.id === active.id) continue;
      if (tab.isDirty || activeEditor?.isDirty(tab.path)) { preserved++; continue; }
      tabManager.closeTab(tab.id);
    }
    if (preserved) notice(`Se conservan ${preserved} pestañas con cambios sin guardar.`, 'info');
  };
  // F6 (10-nov): los atajos ya no son manejadores fijos. Cada
  // comando de esta lista lleva su atajo por defecto, el usuario puede
  // cambiarlo en Configuración › Acerca de y ayuda, y un único despachador en
  // captura (antes de Monaco) los atiende: keybindings.ts.
  const paletteCommands = [
    { id: 'palette.show', label: 'Mostrar la paleta de comandos', category: 'Vista', shortcut: 'Ctrl+Shift+P', action: () => commandPalette.show() },
    { id: 'settings.open', label: 'Abrir Configuración', category: 'Vista', shortcut: 'Ctrl+,', action: () => router.show('settings') },
    { id: 'nav.back', label: 'Atrás', category: 'Vista', shortcut: 'Alt+←', action: () => router.back() },
    { id: 'nav.forward', label: 'Avanzar', category: 'Vista', shortcut: 'Alt+→', action: () => router.forward() },
    { id: 'editor.splitVertical', label: 'Dividir editor vertical', category: 'Editor', action: () => { router.showEditor(); return activeEditor?.split('vertical'); } },
    { id: 'editor.splitHorizontal', label: 'Dividir editor horizontal', category: 'Editor', action: () => { router.showEditor(); return activeEditor?.split('horizontal'); } },
    { id: 'editor.closeSplit', label: 'Cerrar panel dividido', category: 'Editor', action: () => activeEditor?.closeSplit() },
    { id: 'search.replaceInFiles', label: 'Reemplazar en archivos', category: 'Búsqueda', action: () => router.showReplaceInFiles() },
    { id: 'diff.nextHunk', label: 'Hunk siguiente', category: 'Diff', action: () => { router.show('diff'); diffViewer?.navigateHunk(1); } },
    { id: 'diff.prevHunk', label: 'Hunk anterior', category: 'Diff', action: () => { router.show('diff'); diffViewer?.navigateHunk(-1); } },
    { id: 'editor.formatDocument', label: 'Formatear documento', category: 'Editor', action: () => activeEditor?.formatDocument() },
    { id: 'file.saveAll', label: 'Guardar todo', category: 'Archivo', shortcut: 'Ctrl+Shift+S', action: saveAllFiles },
    { id: 'file.closeOthers', label: 'Cerrar otras pestañas', category: 'Archivo', action: closeOtherTabs },
    { id: 'editor.goToLine', label: 'Ir a línea', category: 'Editor', shortcut: 'Ctrl+G', action: () => activeEditor?.goToLine() },
    { id: 'editor.toggleWordWrap', label: 'Ajuste de línea', category: 'Editor', shortcut: 'Alt+Z', action: () => activeEditor?.toggleWordWrap() },
    { id: 'editor.toggleMinimap', label: 'Minimapa del editor', category: 'Editor', action: () => activeEditor?.toggleMinimap() },
    { id: 'window.zoomIn', label: 'Zoom +', category: 'Vista', shortcut: 'Ctrl++', action: () => changeWindowZoom(10) },
    { id: 'window.zoomOut', label: 'Zoom −', category: 'Vista', shortcut: 'Ctrl+-', action: () => changeWindowZoom(-10) },
    { id: 'window.resetZoom', label: 'Restablecer zoom de la ventana', category: 'Vista', shortcut: 'Ctrl+0', action: () => changeWindowZoom(null) },
    {
      id: 'browser.toggle',
      label: 'Abrir u ocultar el navegador integrado',
      category: 'Vista',
      action: toggleBrowser,
    },
    // QA primerizo (10-nov): la paleta no tenía ningún comando de terminal y
    // Ctrl+` no existe en el teclado español; Ctrl+Ñ es el de VS Code en ES.
    {
      id: 'terminal.toggle',
      label: 'Abrir u ocultar la terminal integrada',
      category: 'Vista',
      shortcut: 'Ctrl+Ñ',
      action: () => toggleTerminalView(),
    },
    {
      id: 'view.agent',
      label: 'Ir a: Agente',
      category: 'Navegación',
      action: () => router.show('agent'),
    },
    {
      id: 'view.explorer',
      label: 'Ir a: Explorador de archivos',
      category: 'Navegación',
      action: () => router.show('explorer'),
    },
    {
      id: 'view.settings',
      label: 'Ir a: Configuración',
      category: 'Navegación',
      action: () => router.show('settings'),
    },
    {
      id: 'view.mcp',
      label: 'Ir a: Conectores MCP',
      category: 'Navegación',
      action: () => router.show('mcp'),
    },
    {
      id: 'view.monitor',
      label: 'Ir a: Monitor',
      category: 'Navegación',
      action: () => router.show('monitor'),
    },
    {
      id: 'view.search',
      label: 'Ir a: Búsqueda global',
      category: 'Navegación',
      action: () => router.show('search'),
    },
    {
      id: 'view.spaces',
      label: 'Ir a: Spaces y sesiones',
      category: 'Navegación',
      action: () => router.show('spaces'),
    },
    {
      id: 'view.issues',
      label: 'Ir a: Incidencias',
      category: 'Navegación',
      action: () => router.show('issues'),
    },
    {
      id: 'panel.toggle',
      label: 'Mostrar u ocultar el panel de actividad',
      category: 'Vista',
      action: togglePanel,
    },
    {
      id: 'file.save',
      label: 'Guardar archivo actual',
      category: 'Archivo',
      shortcut: 'Ctrl+S',
      action: () => activeEditor?.saveCurrentFile(),
    },
    {
      id: 'file.saveAs',
      label: 'Guardar archivo como…',
      category: 'Archivo',
      action: () => activeEditor?.saveCurrentFileAs(),
    },
    {
      id: 'file.review',
      label: 'Revisar cambios del archivo actual (por bloques)',
      category: 'Archivo',
      shortcut: 'Ctrl+Shift+D',
      action: () => void reviewCurrentFile(),
    },
    {
      id: 'engine.discover',
      label: 'Motor: descubrir modelos de los proveedores con clave',
      category: 'Motor',
      action: () => {
        // El resultado (y cualquier fallo) se ve en la propia sección de
        // Modelos, que es donde el usuario puede actuar sobre él.
        router.show('settings');
        settingsPanel?.showSection?.('models');
        void core.discoverModels().catch(() => undefined);
      },
    },
    {
      id: 'engine.screenshot',
      label: 'Capturar la pantalla en un archivo',
      category: 'Motor',
      action: () => {
        void core
          .captureScreenshot()
          .then((r) => {
            if (!r?.ok || !r.path) {
              notice('No se pudo capturar la pantalla: ' + (r?.error || 'motivo desconocido'), 'error');
              return;
            }
            notice(`Pantalla capturada (${r.width}×${r.height})\n${r.path}`, 'ok', 8000);
          })
          .catch((e) => notice('No se pudo capturar la pantalla: ' + String(e), 'error'));
      },
    },
    {
      id: 'workspace.set',
      label: 'Cambiar la carpeta de trabajo del agente',
      category: 'Entorno',
      action: () => void changeWorkspaceRoot(),
    },
    ...themeManager.getAvailableThemes().map((t) => ({
      id: `theme.${t.id}`,
      label: `Tema: ${t.name}`,
      category: 'Apariencia',
      action: () => themeManager.applyTheme(t.id),
    })),
    {
      id: 'help.open',
      label: 'Abrir ayuda y preguntas frecuentes',
      category: 'Ayuda',
      action: () => helpPanel.show(),
    },
  ];
  commandPalette.registerCommands(paletteCommands);
  // 12-nov: comandos «/» del compositor que reutilizan la paleta y las vistas
  // (los nombres de Claude Code y Codex).
  const paletteAction = (id: string) => () => paletteCommands.find((c) => c.id === id)?.action();
  missionControl?.setSlashExtras([
    { nombre: '/review', desc: 'Revisar por bloques los cambios del archivo abierto', run: paletteAction('file.review') },
    {
      nombre: '/memory',
      desc: 'Abrir AGENTS.md (o CLAUDE.md), la memoria del proyecto',
      run: () =>
        void core
          .listDir('')
          .then(({ entries }) => {
            const guide = ['AGENTS.md', 'CLAUDE.md']
              .map((n) => entries.find((e) => !e.isDir && e.name === n))
              .find((e) => e !== undefined);
            if (guide) openFile(guide.path, guide.name);
            else notice('El proyecto no tiene AGENTS.md ni CLAUDE.md: créalo con /init.', 'info');
          })
          .catch((error: unknown) => notice('No se pudo leer la carpeta del proyecto: ' + String(error), 'error')),
    },
    { nombre: '/usage', desc: 'Presupuesto, llamadas de pago y cuotas', run: () => document.getElementById('status-paid-budget')?.click() },
    {
      nombre: '/resume',
      desc: 'Retomar una conversación anterior (lista de sesiones)',
      run: () => {
        paletteAction('view.agent')();
        requestAnimationFrame(() => document.querySelector<HTMLInputElement>('#sb-sess-filter')?.focus());
      },
    },
    { nombre: '/diff', desc: 'Ver los cambios del proyecto', run: () => router.show('diff') },
    { nombre: '/status', desc: 'Estado del motor, órdenes y modelos (Monitor)', run: paletteAction('view.monitor') },
    { nombre: '/mcp', desc: 'Conectores MCP', run: paletteAction('view.mcp') },
    { nombre: '/help', desc: 'Ayuda y preguntas frecuentes', run: paletteAction('help.open') },
  ]);
  registerBindableCommands(paletteCommands);
  installKeybindings();

  document.addEventListener('keydown', (e) => {
    // Ctrl+Enter dentro del editor: autocompletar desde el comentario.
    if (e.ctrlKey && !e.shiftKey && e.key === 'Enter') {
      const inEditor = (e.target as HTMLElement)?.closest('#monaco-editor-container');
      if (inEditor) {
        e.preventDefault();
        void completeFromComment();
      }
    }
  });

  // E5.22 — «Abrir en ventana nueva». El gesto llega por tres vías (el ⧉ de
  // la pestaña del editor, el ⧉ del panel inferior y el evento
  // devagents:open-window que publican chat y monitor) y todas acaban en el
  // mismo verbo del puente, que el host valida con ParseOpenWindow.
  document.getElementById('btn-browser')?.addEventListener('click', toggleBrowser);
  const openSecondary = (vista: string, extra: Record<string, unknown> = {}) => {
    void bridgeClient
      .send<Record<string, unknown>, { error?: string }>('window.open', { vista, ...extra })
      .catch((e) => notice('No se pudo abrir la ventana: ' + String(e), 'error'));
  };
  tabManager.onTabPopout((tab) => openSecondary('editor', { path: tab.path }));
  document.getElementById('btn-popout-bottom')?.addEventListener('click', () => openSecondary('terminal'));
  document.addEventListener('devagents:open-window', (e) => {
    const vista = String((e as CustomEvent).detail?.vista || '');
    if (!vista) return;
    const extra: Record<string, unknown> = {};
    if (vista === 'conversacion') {
      const oid = missionControl?.getActiveOrderId() ?? 0;
      if (oid > 0) extra.order_id = oid;
    }
    openSecondary(vista, extra);
  });

  /**
   * E5.22 — modo ventana secundaria: la cabina arrancó entera (puente,
   * paneles, listeners) y ahora solo una superficie queda a la vista. El
   * panel se MUEVE dentro de #ventana-unica — no se reconstruye — para
   * conservar el estado vivo (el transcript del chat, la sesión ConPTY,
   * el modelo de Monaco).
   */
  const activateSecondaryWindow = (q: NonNullable<typeof winQuery>): void => {
    const titles: Record<string, string> = {
      editor: 'Editor',
      terminal: 'Terminal',
      conversacion: 'Conversación',
      monitor: 'Monitor',
    };
    document.title = `${titles[q.vista] || q.vista} — DevAgents` + (q.ventana > 0 ? ` · ventana ${q.ventana}` : '');
    const plan = secondaryMountPlan(q.vista);
    // D1/D2: el panel inferior se monta de forma perezosa — sin
    // showSidePanel('terminal') no hay xterm ni sesión que mover (D1). La
    // conversación real vive en #pane-mission-container (transcript +
    // compositor) y se puebla con router.show('agent') (D2), no con el
    // panel de actividad.
    if (plan.sidePanel) router.showSidePanel(plan.sidePanel);
    else if (q.vista === 'conversacion') router.show('agent' as ViewId);
    const pane = mountSecondaryView(plan.paneId);
    if (!pane) { mountSecondaryFallback(q.vista); return; }
    switch (q.vista) {
      case 'editor':
        if (q.path) void activeEditor?.openFile(q.path);
        break;
      case 'terminal':
        pane.dataset.collapsed = 'false';
        window.dispatchEvent(new Event('resize'));
        break;
      case 'conversacion':
        if (q.order > 0) void openSession(q.order);
        break;
      case 'monitor':
        void monitorPanel?.refresh();
        monitorPanel?.startAutoRefresh(5000);
        break;
    }
  };

  // 8. Vista inicial y sondeo de estado del motor. En ventana secundaria no
  // hay barra de estado que refrescar ni navegación inicial: solo el panel.
  if (winQuery) {
    hideBootSplash();
    activateSecondaryWindow(winQuery);
    return;
  }

  router.show('agent' as ViewId);

  const workspaceWarning = document.createElement('div');
  workspaceWarning.className = 'workspace-warning';
  workspaceWarning.setAttribute('role', 'status');
  workspaceWarning.style.cssText = 'position:fixed;left:16px;bottom:40px;z-index:1000;gap:10px;padding:10px;background:var(--bg-panel);border:1px solid var(--border)';
  workspaceWarning.hidden = true;
  workspaceWarning.append('Elige una carpeta de proyecto autorizada para empezar.');
  const chooseWorkspace = document.createElement('button');
  chooseWorkspace.type = 'button';
  chooseWorkspace.className = 'btn';
  chooseWorkspace.textContent = 'Elegir carpeta';
  chooseWorkspace.onclick = () => void changeWorkspaceRoot();
  workspaceWarning.append(chooseWorkspace);
  document.body.append(workspaceWarning);
  document.addEventListener('devagents:workspace-changed', () => { workspaceWarning.hidden = true; });

  const syncStatus = async () => {
    try {
      const st = await core.status();
      workspaceWarning.hidden = st.workspaceRoot !== '';
      updateEngineStatus({
        online: st.engineReady,
        pid: st.pid,
        version: st.version,
        governanceMode: governanceLabel(st.governanceMode),
        model: st.activeModel,
        keyLabel: st.keyLabel,
      });
    } catch {
      updateEngineStatus({
        online: false,
        pid: 0,
        // sin motor no se inventa la versión desde un literal; se
        // deja vacía para que `formatEngineVersion` muestre «—».
        version: '',
        governanceMode: '—',
        model: '—',
        keyLabel: '—',
      });
    }
  };
  // La primera respuesta del motor (o su fallo) retira el icono de arranque.
  void syncStatus().finally(() => hideBootSplash());
  window.setInterval(syncStatus, 5000);

  // — avisos de órdenes (terminó, falló, pide aprobación, pregunta)
  // y bandeja de no leídos. Se alimentan de la lista de sesiones del motor, que
  // ve TODAS las órdenes, no solo la abierta.
  const attention = new AttentionCenter({
    openApproval: (approvalId) => {
      if (!monitorPanel) return false;
      router.show('monitor');
      monitorPanel.revealApproval(approvalId);
      return true;
    },
    openOrder: async (orderId, conversationId) => {
      if (missionControl?.isBusy() && missionControl.getActiveOrderId() !== orderId) {
        await openSession(orderId, conversationId); // explica por qué no se abre
        return false;
      }
      if (missionControl?.isBusy()) { router.show('agent'); return true; }
      await openSession(orderId, conversationId);
      return true;
    },
    onError: (message) => notice(message, 'error'),
  });
  const attentionButton = document.getElementById('btn-attention') as HTMLButtonElement | null;
  if (attentionButton) new AttentionTray(attention, attentionButton);
  const pollAttention = async () => {
    const [sessions, approvals] = await Promise.allSettled([
      core.listSessions('active'), core.pendingApprovals(),
    ]);
    if (sessions.status === 'fulfilled') attention.observe(sessions.value);
    if (approvals.status === 'fulfilled') attention.observeApprovals(approvals.value);
    else attention.approvalsUnavailable(String(approvals.reason));
  };
  void pollAttention();
  window.setInterval(pollAttention, 5000);
});

function governanceLabel(mode: string): string {
  if (mode === 'free' || mode === 'free_tier_first') return 'Solo gratis';
  if (mode === 'paid' || mode === 'paid_tier_first') return 'Prioriza pago';
  if (mode === 'hybrid') return 'Híbrido';
  if (mode === 'local' || mode === 'local_only' || mode === 'solo_local') return 'Solo local';
  return mode || '—';
}
