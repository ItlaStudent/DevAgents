import { escapeText as esc, escapeAttribute, html as safeHtml, joinHtml, raw, SafeHtml } from '../design/html';
import { externalModelRows } from '../external_models';
import { CoreApi, ExternalAgent, OrderEvent, PrItem, BestOfNCard, BestOfNCandidate, eventPayload, IssueRequest } from '../bridge/core_api';
import { issueInstruction } from '../issue_draft';
import { describeProviderFailure, synthProblems, terminalOrderPhase, workspaceRestoreDiagnostic } from '../ui_diag';
import { icons, brandEmblem } from '../design/icons';
import { previewHtml } from '../editor/diff_viewer';
import { orbitBackdrop } from '../design/orbit_backdrop';
import { updatePermissionBadge } from '../layout/layout';
import { renderMarkdown } from '../design/markdown';
import { installCodeCopy } from '../design/code_copy';
import { artifactAction, ArtifactAction, runnerFor } from '../file_runtime';
import * as act from '../chat_activity';
import * as autoc from './auto_compact';
import * as ctxuse from './context_usage';
import { conversationIdForSession } from '../session_groups';
import { notice } from '../design/notice';
import { buildOrderGraph, graphEnabledNow, orderDotsMarkup, orderGraphMarkup, setGraphEnabled } from './order_graph';

/** Un comando `/` del compositor. */
export interface SlashCommand {
  nombre: string;
  desc: string;
  run: () => void;
}
import * as cornerAlerts from '../design/alerts';

// Las alertas de esquina son avisos: si fallan (entorno sin DOM, módulo no
// cargado), NUNCA deben impedir enviar una orden ni repintar el compositor.
function raiseAlert(spec: cornerAlerts.AlertSpec): void {
  try { cornerAlerts.raiseAlert?.(spec); } catch (e) { console.warn('[alertas]', e); }
}
function clearAlert(id: string): void {
  try { cornerAlerts.clearAlert?.(id); } catch (e) { console.warn('[alertas]', e); }
}
function clearAlertsExcept(prefix: string, keep: Set<string>): void {
  try { cornerAlerts.clearAlertsExcept?.(prefix, keep); } catch (e) { console.warn('[alertas]', e); }
}
import { statusLabel, departmentLabel } from '../design/status_labels';
import { confirmModal } from '../design/modal';
import { installCopyImageMenu } from '../components/copy_image_menu';
import { ImageAttachment, MAX_IMAGE_BYTES, readImageAttachment } from '../image_attachments';

/**
 * proyecto reservado para la orden interna de compactacion.
 *
 * El historial es del USUARIO: la orden que solo pide el resumen no es suya y
 * no debe aparecer en la barra lateral ni titular una sesion. El motor ya
 * oculta toda orden cuyo `project_id` empieza por el prefijo interno `__`
 * (core/src/session_store.zig:36 `INTERNAL_PROJECT_PREFIX` y su filtro en
 * :169; core/src/c_api.zig:6611 para la lista en memoria). Antes esta orden
 * nacia con `'default'` — el mismo proyecto que las ordenes del usuario —, asi
 * que su prompt interno quedaba en el historial como si lo hubiera escrito el
 * usuario (defecto reportado en agosto). Basta con nacer interna.
 */
const COMPACTION_PROJECT = '__compact';

export interface PlanQuestion {
  id: string;
  text: string;
  options: string[];
}

export interface PlanTask {
  id: string;
  task_type: string;
  department: string;
  description: string;
  depends_on: string[];
  /** B1: archivos que la tarea produce (propiedad auditable). */
  owns?: string[];
  /** B1: entregable al que pertenecen esos archivos. */
  deliverable?: string;
}

export interface OrderPlan {
  wait_for_plan_approval?: boolean;
  understanding?: string;
  needs_clarification?: boolean;
  questions?: PlanQuestion[];
  tasks?: PlanTask[];
}

type ThreadTurn = { role: 'user' | 'assistant'; text: string; failed?: boolean };

/**
 * una orden TERMINADA de la conversación, conservada en el hilo en
 * vez de borrarse cuando llega la siguiente. Vive aparte de la orden en curso:
 * sus botones no comparten id ni manejador con los de `this.orderId`, y el
 * único que actúa (Revertir) usa SU punto de control.
 */
export interface PriorOrder {
  orderId: number;
  /** Estado legible del motor (`done`, `failed`, `planned`…); pasa por statusLabel. */
  status: string;
  /**
   * `work` se pliega en un bloque con resumen; `chat` se queda como burbujas
 * normales del hilo (decisión del propietario, r3) y no carga actividad de trabajo.
   * `unknown` (r4) es una orden del hilo cuya clasificación aún no se conoce:
   * NO se pinta como bloque de trabajo —eso afirmaría algo que no se sabe— y se
   * muestra como mensajes hasta que su plan la clasifique.
   */
  kind: 'chat' | 'work' | 'unknown';
  turns: ThreadTurn[];
  plan: OrderPlan | null;
  /** Vacío hasta que se despliega (o se hidrata con cota); ver `boundEvents`. */
  events: OrderEvent[];
  eventsLoaded: boolean;
  planLoaded: boolean;
  /** Mensaje del último fallo al leer el plan (r4 P2); vacío si no falló. */
  planError: string;
  /** A7 (10-nov): fallo al leer los eventos de una orden sin tareas; vacío si no falló. */
  eventsError?: string;
  loading: boolean;
  open: boolean;
  checkpoint: { sha: string; untracked: number } | null;
  checkpointRoot: string;
  checkpointMsg: string;
  /**
   * B1d (11-nov): vuelta de Directo/DevAgents (punto de control tomado al
   * enviar, no al aprobar un plan). Su «Revertir» va compacto bajo la
   * respuesta, no dentro del grupo plegado.
   */
  turn?: boolean;
}

export interface MissionControlHooks {
  /** Llevar al usuario a la vista de Configuración (no hay claves, etc.). */
  onRequestSettings?: () => void;
  /** Cambiar a modo Dev (editor). */
  onRequestDevMode?: () => void;
  /** Reflejar en el panel lateral lo que va ocurriendo. */
  onActivity?: (kind: 'status' | 'events' | 'plan', data: unknown) => void;
  /**
   * UI-ACTION: un evento `ui_action` de la orden pide una acción cosmética
   * sobre la cabina (tema, vista, sesión, notificación). El dispatcher lo
   * revalida contra su allowlist y responde el ack al motor.
   */
  onUiAction?: (eventId: number, payload: unknown) => void;
  /** 10-nov: un agente pidió el navegador integrado para esta orden. */
  onBrowserNeeded?: (orderId: number) => void;
}

/**
 * `chat` es una fase de pleno derecho, no un caso raro de `awaiting-approval`.
 *
 * El planner ya distinguía la charla de la construcción — devuelve
 * `{"kind":"chat"}` con `tasks: []` y la respuesta en `understanding` — pero la
 * interfaz mandaba todo por el mismo embudo, así que un "Hola" acababa con un
 * botón "Aprobar y ejecutar" delante. En modo Agente se puede conversar; el
 * ciclo de planificar/aprobar/despachar aparece solo cuando hay tareas.
 */
type Phase =
  | 'idle'
  | 'planning'
  | 'clarifying'
  | 'chat'
  | 'awaiting-approval'
  | 'running'
  | 'done'
  | 'interrupted'
  // AUDIT-UNAVAILABLE-P0: ejecución terminada sin veredicto de auditoría
  // usable — entrega bloqueada hasta el reintento manual del usuario.
  | 'audit-unavailable'
  // E5.18 (DaOrderStatus 12): las N candidatas terminaron y la orden espera
  // la elección del ganador — no es terminal; la fusión es decisión humana.
  | 'best-of-n'
  | 'error';

/**
 * Centro de mando: la vista por defecto de la cabina.
 *
 * Conduce el ciclo completo de una orden contra el motor —
 * submit → planificar → (aclarar) → aprobar → despachar → eventos —
 * en vez del eco `ping` que tenía la maqueta.
 */
export class MissionControlPanel {
  private container: HTMLElement;
  private core: CoreApi | null;
  private hooks: MissionControlHooks;

  private phase: Phase = 'idle';
  private orderId = 0;
  private plan: OrderPlan | null = null;
  private lastEventId = 0;
  private events: OrderEvent[] = [];
  private pollHandle: number | null = null;
  /** D9: sondeo del estado real de la orden mientras el panel espera al usuario. */
  private statusWatchHandle: number | null = null;
  private startedAt = 0;
  private mode: 'agent' | 'dev' = 'agent';
  /** sugerencia inline pendiente de aceptar (modo Dev, Ctrl+Espacio). */
  private pendingSuggestion = '';
  private inlineSuggestionPending = false;
  private hasKeys = false;

  /**
   * Identificador del hilo actual. Viaja en cada `submitOrder` y es lo que
   * permite al motor recuperar los turnos anteriores. Se renueva al empezar una
   * conversación nueva, no al terminar una orden: encadenar órdenes dentro del
   * mismo hilo es justamente lo que da continuidad.
   */
  private conversationId = newConversationId();
  /** Evita que una lectura lenta reemplace la sesión que el usuario acaba de abrir. */
  private sessionLoadEpoch = 0;
  /** Invalida respuestas asíncronas de una planificación que ya no es actual. */
  private orderEpoch = 0;
  /** El motor aceptó la solicitud, pero todavía no confirmó el estado terminal. */
  private cancelPending = false;
  private cancelError = '';
  /** Transcripción local, solo para pintar. La fuente de verdad es el motor. */
  /**
   * `failed` marca un turno que NO es una respuesta, sino un fallo del
   * proveedor disfrazado de respuesta. Ver `isProviderFailure`.
   */
  private turns: ThreadTurn[] = [];

  /**
 * órdenes anteriores del MISMO hilo, plegadas encima de la orden
   * en curso. `turns` sigue siendo la transcripción plana completa (peso del
   * contexto, compactación, reintento); los primeros `priorTurnCount` turnos
   * pertenecen a esas órdenes y se pintan dentro de ellas, no en el hilo vivo.
   */
  private priorOrders: PriorOrder[] = [];
  private priorTurnCount = 0;
  /** Eventos que se conservan en memoria de las órdenes anteriores (el resto, al desplegar). */
  private static readonly PRIOR_EVENTS_KEEP = 3;

  /** Foto del árbol tomada justo antes del despacho; null si no se pudo. */
  private checkpoint: { sha: string; untracked: number } | null = null;
  private checkpointError = '';
  private checkpointMsg = '';
  /** Raiz sobre la que se tomo la foto (worktree de la orden o workspace). */
  private checkpointRoot = '';
  /**
   * B1d (11-nov): el punto de control en curso se tomó al ENVIAR una vuelta
   * de Directo/DevAgents (como Codex o Claude Code, uno por vuelta). Se ofrece
   * solo si esa vuelta escribió archivos (`turnWrote`); si no, ni «Revertir»
   * ni «Sin punto de control».
   */
  private turnCheckpoint = false;
  /**
   * P1-8 (11-nov): esta sesión de la cabina intentó tomar el punto de control
   * de la orden en curso. Los puntos de control viven en memoria; al reabrir
   * una orden del historial no hay ninguno que ofrecer y tampoco hubo un fallo
   * que contar, así que no se pinta «Sin punto de control».
   */
  private checkpointAttempted = false;

  /** B3: PRs reales de esta orden (filas de pull_requests via core.prs). */
  private shipPrs: PrItem[] = [];
  private shipBusy = false;
  /** Borrador del observable declarado en la tarjeta de aprobación (sobrevive re-renders). */
  private expectedDraft = '';
  private shipError = '';
  /** T4-GITEA: rama empujada sin credencial de API — el PR se abre a mano. */
  private shipManual: { url: string; branch: string } | null = null;

  /**
 * preferencia del usuario capturada en la orden del motor.
   * El plan usa las mismas acciones de aprobación y edición que antes.
   */
  private planOnly = false;
  /** Forma de trabajar «Directo» (un modelo, como una CLI). Es la
 * de por defecto (propietario, 8-nov: «que funcione como una IDE normal desde el
   *  inicio»); Orquestado y Colmena se eligen en Modos y se recuerdan. */
  private directMode = readWorkMode() === 'directo' || readWorkMode() === 'devagents';
  /** USUARIO-NUEVO B: modo «DevAgents» (Directo + delegar). Implica `directMode`. */
  private delegateMode = readWorkMode() === 'devagents';
  private planChangeDraft = '';

  private setPlanMode(enabled: boolean): void {
    this.planOnly = enabled;
    try { window.localStorage.setItem('devagents.waitPlanApproval.v1', String(enabled)); }
    catch { notice('No se pudo guardar la preferencia de aprobación del plan.', 'error'); }
    const control = this.container.querySelector<HTMLInputElement>('#wait-plan-approval');
    if (control) control.checked = enabled;
    this.renderModeChips();
    this.renderBody();
  }
  /** E2.14: true mientras el host tiene ES_DISPLAY_REQUIRED activo por una orden viva. */
  private keepAwakeActive = false;
  /**
   * B2/E2.4: pin del planificador capturado AL ENVIAR la orden. El selector
   * puede cambiar después y la orden sigue con el suyo — esta copia es la que
   * se muestra en la tarjeta para que el pin efectivo sea visible.
   */
  private orderPin = '';
  /**
   * Borrador del editor de plan (JSON). Igual que expectedDraft: el textarea
   * vive solo en el DOM y cualquier renderBody() lo recrearía vacío, así que
   * el texto tecleado se respalda aquí hasta guardarlo o cambiar de orden.
   */
  private planEditDraft: string | null = null;

  /** Texto citado e imágenes validadas; la imagen viaja separada del prompt. */
  private attachments: Array<{ name: string; content: string } | ImageAttachment> = [];
  private attachQueue: Promise<void> = Promise.resolve();
  private attachmentReads = 0;
  /**
   * D6: estado de la compactación automática de ESTE hilo (umbral, cuenta
   * atrás, posponer y fallo previo). La decisión vive en `auto_compact.ts`,
   * que se prueba sin DOM; aquí solo queda el reloj y el pintado.
   */
  private autoCompact: autoc.EstadoAutoCompactacion = autoc.estadoInicial();
  /** Reloj de la cuenta atrás. Solo corre cuando hay una en marcha. */
  private autoCompactTimer: number | null = null;
  private attachError = '';

  constructor(container: HTMLElement, core?: CoreApi, hooks: MissionControlHooks = {}) {
    this.container = container;
    this.core = core ?? null;
    this.hooks = hooks;
    try { this.planOnly = window.localStorage.getItem('devagents.waitPlanApproval.v1') === 'true'; }
    catch { this.planOnly = false; }
    this.render();
    // Acciones del grafo de la orden: delegadas, porque el bloque de actividad
    // se repinta entero con cada evento.
    this.container.addEventListener('click', (ev) => {
      const node = (ev.target as Element | null)?.closest<SVGGElement>('[data-graph-node]');
      if (node) {
        this.selectGraphNode(node.dataset.graphNode ?? '');
        return;
      }
      const button = (ev.target as HTMLElement | null)?.closest<HTMLElement>('[data-graph-act]');
      if (!button) return;
      const act = button.dataset.graphAct;
      if (act === 'show' || act === 'hide') {
        setGraphEnabled(act === 'show');
        const box = this.container.querySelector<HTMLInputElement>('#chk-order-graph');
        if (box) box.checked = act === 'show';
        this.renderBody();
      } else if (act === 'retry') {
        const retry = this.container.querySelector<HTMLElement>('#btn-mission-retry');
        if (retry) retry.click();
        else notice('Reintentar la orden está disponible cuando la orden ha terminado con un fallo.', 'info');
      } else if (act === 'model') {
        this.container.querySelector<HTMLElement>('#btn-model-picker')?.click();
      } else if (act === 'log') {
        const scope = button.closest('[data-order-graph]')?.parentElement;
        const details = Array.from(scope?.querySelectorAll<HTMLDetailsElement>('details') ?? []);
        details.forEach((d) => (d.open = true));
        if (details[0]) details[0].scrollIntoView({ block: 'nearest' });
        else notice('Esta orden no tiene registro de actividad que mostrar.', 'info');
      }
    });
    this.container.addEventListener('keydown', (ev) => {
      if (ev.key !== 'Enter' && ev.key !== ' ') return;
      const node = (ev.target as Element | null)?.closest<SVGGElement>('[data-graph-node]');
      if (!node) return;
      ev.preventDefault();
      this.selectGraphNode(node.dataset.graphNode ?? '');
    });
    this.container.addEventListener('change', (ev) => {
      const box = ev.target as HTMLInputElement | null;
      if (box?.id !== 'chk-order-graph') return;
      setGraphEnabled(box.checked);
      this.renderBody();
    });
    void this.refreshStatus();

    // B2/E2.4 — desync del selector de modelo: los pines también cambian desde
    // Configuración y desde fuera (MCP/CLI). Al volver a la ventana, o cuando
    // otro panel avisa, se releen del motor en vez de mostrar el pin viejo.
    document.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'visible' && this.core) void this.refreshModelPickers();
    });
    document.addEventListener('devagents:models-changed', () => {
      if (this.core) void this.refreshModelPickers();
    });
    // La tarjeta «Contexto» puede montarse después de la última publicación
    // de renderBody(); al montar pide el uso vigente y se le re-emite.
    document.addEventListener('devagents:thread-usage-request', this.onThreadUsageRequest);

    // E2.6 — «Ejecutar esto»: delegado en el contenedor para seguir vivo tras
    // cada repintado del hilo. El comando sale del <code> del bloque, no de un
    // atributo: lo que se ejecuta es exactamente lo que el usuario lee.
    this.container.addEventListener('click', (ev) => {
      const btn = (ev.target as HTMLElement).closest?.('.md-cmd__run');
      if (!btn) return;
      const code = btn.closest('pre')?.querySelector('code')?.textContent ?? '';
      if (!code.trim()) return;
      document.dispatchEvent(new CustomEvent('devagents:run-command', { detail: code }));
    });

    // QA primerizo (11-nov): «Sin punto de control» ofrece crear el repositorio.
    this.container.addEventListener('click', (ev) => {
      // USUARIO-NUEVO B: el mismo botón aparece cuando una delegación no pudo
      // abrir worktrees por falta de git (`data-git-init`).
      const btn = (ev.target as HTMLElement).closest?.('#btn-git-init, [data-git-init]') as HTMLButtonElement | null;
      if (!btn || !this.core) return;
      btn.disabled = true;
      void this.core.gitInit(this.checkpointRoot).then(() => {
        this.checkpointError = '';
        this.checkpointMsg = 'Repositorio git creado. La próxima orden guardará un punto de control antes de tocar nada.';
        notice('Repositorio git creado en la carpeta de trabajo.', 'ok');
        this.render();
      }, (e) => {
        btn.disabled = false;
        notice(`No se pudo crear el repositorio: ${String(e instanceof Error ? e.message : e)}`, 'error');
      });
    });

    // — «Copiar» en cada bloque de código (delegado, como el de arriba).
    installCodeCopy(this.container);

    // E2.17 — menú contextual «Copiar imagen»: rasteriza el bloque (tarjeta,
    // turno, comando) al portapapeles como PNG. Instalado en el contenedor para
    // sobrevivir a los repintados del cuerpo; la lógica es compartida porque el
    // transcript central (ChatPanel) la necesita igual.
    installCopyImageMenu(this.container);
  }

  /** Compatibilidad con el arranque previo; el plan real manda sobre esto. */
  public setTasks(tasks: unknown[]): void {
    if (Array.isArray(tasks) && tasks.length === 0 && this.phase === 'idle') this.renderBody();
  }

  /**
   * El conmutador Agente/Dev ya no vive en este panel (se plegaba junto con
   * el editor al entrar en modo Dev); ahora vive siempre visible en la barra
   * de pestañas (`layout.ts`, `#mode-agent`/`#mode-dev`). Este panel solo
   * conserva el estado, sin gestionar listeners ni marcado propio.
   */
  public setMode(mode: 'agent' | 'dev'): void {
    this.mode = mode;
  }

  public getMode(): 'agent' | 'dev' {
    return this.mode;
  }

  /** Una orden activa conserva su sondeo y no se puede sustituir por un Replay. */
  public isBusy(): boolean {
    // best-of-n: el hilo de despacho terminó pero la orden sigue abierta
    // esperando la elección — cambiar de sesión perdería la tarjeta.
    return this.phase === 'planning' || this.phase === 'clarifying' || this.phase === 'running' || this.phase === 'best-of-n';
  }

  public canOpenSession(): boolean {
    return !this.isBusy();
  }

  /** Orden que la sesión tiene cargada (0 = ninguna). La usa el gesto «Abrir en ventana nueva». */
  public getActiveOrderId(): number {
    return this.orderId;
  }

  /** No se abandona una orden que aún necesita respuesta, aprobación o ejecución. */
  public canStartNewConversation(): boolean {
    return !this.isBusy() && this.phase !== 'awaiting-approval';
  }

  private pendingIssue: { request: IssueRequest; prompt: string } | null = null;

  public importIssue(request: IssueRequest, prompt: string): void {
    if (!this.canStartNewConversation()) throw new Error('Termina o descarta la orden actual antes de importar una incidencia.');
    this.newConversation();
    const input = this.container.querySelector<HTMLTextAreaElement>('#mission-composer-input');
    if (!input) throw new Error('El compositor no está disponible.');
    const quoted = prompt.trim();
    if (!quoted) throw new Error('El motor devolvió un bloque de incidencia vacío.');
    this.pendingIssue = { request, prompt: quoted };
    input.value = quoted;
    input.focus();
    input.setSelectionRange(0, 0);
  }

  /**
 * · item 20 — el modo Dev hace algo: sugiere código inline.
   *
   * Antes `setMode` escribía un campo que nadie leía (el «interruptor
 * muerto» de). Decisión del propietario: conectar Dev a sugerencias de
   * código con Ctrl+Espacio sobre el texto del compositor. En modo Agente
   * Ctrl+Espacio no hace nada — las órdenes del agente no son código.
   *
   * La sugerencia va delante al texto SIN autoinsertarse: se pinta bajo el
   * cursor como `ghost text` con Tab para aceptar. Autoinsertar sería robar
   * el teclado al usuario.
   */
  private suggestInline(input: HTMLTextAreaElement | null): void {
    if (!input || this.mode !== 'dev') return;
    const prompt = input.value;
    if (!prompt.trim()) return;
    if (this.inlineSuggestionPending) return;
    this.inlineSuggestionPending = true;
    const prev = input.value;
    this.core
      ?.completeText(prompt, '')
      .then((res) => {
        const suggestion = (res.text ?? '').trim();
        this.inlineSuggestionPending = false;
        if (!suggestion || input.value !== prev) return; // el texto cambió: la sugerencia ya no aplica
        this.pendingSuggestion = suggestion;
        input.setRangeText(suggestion, input.selectionStart ?? prompt.length, input.selectionStart ?? prompt.length, 'end');
        // Ghost: se muestra como selección "futura" sin confirmar no existe
        // en un textarea pelado; la aceptación es explícita con Tab.
        input.dataset['devagentsSuggestion'] = 'tab-para-aceptar';
      })
      .catch(() => {
        this.inlineSuggestionPending = false;
      });
  }

  public async refreshStatus(): Promise<void> {
    if (!this.core) return;
    try {
      const st = await this.core.status();
      this.hasKeys = st.keyCount > 0;
      // QA primerizo (10-nov): «No hay ninguna clave API registrada» salía
      // aunque Ollama o un agente (Claude Code, Codex, OpenCode…) ya pudieran
      // trabajar sin clave. Solo se avisa si no hay NINGUNA forma de trabajar.
      let usable = this.hasKeys;
      if (!usable && typeof this.core.modelSelection === 'function') {
        const rows = await this.core.modelSelection().catch(() => [] as Array<{ provider: string }>);
        usable = rows.some((r) => /^agent:/.test(r.provider) || /ollama|lm ?studio|llama\.?cpp/i.test(r.provider));
      }
      // propietario (10-nov): la franja de arriba pasa a ser una alerta de la
      // esquina (design/alerts.ts): roja si el motor no arrancó, ámbar si no
      // hay ningún modelo. Se retiran solas cuando la condición desaparece.
      const banner = this.container.querySelector<HTMLElement>('#mission-banner');
      if (banner) banner.style.display = 'none';
      const openProviders = { label: 'Configurar', run: () => document.dispatchEvent(new CustomEvent('devagents:settings-section', { detail: 'providers' })) };
      if (!st.engineReady) {
        raiseAlert({ id: 'setup:engine', level: 'error', title: 'El motor no se inicializó', body: st.initError || 'Motivo desconocido.' });
      } else {
        clearAlert('setup:engine');
      }
      if (st.engineReady && !usable) {
        raiseAlert({
          id: 'setup:no-models',
          level: 'warn',
          title: 'No hay ningún modelo disponible',
          body: 'Añade una clave API, abre Ollama con un modelo descargado o inicia sesión en Claude Code, Codex, Gemini CLI u OpenCode.',
          actions: [openProviders, { label: 'Ver el tutorial', run: () => window.dispatchEvent(new CustomEvent('devagents:show-onboarding')) }],
        });
      } else {
        clearAlert('setup:no-models');
      }
      // La píldora "Motor en línea · N proveedores · N claves" que vivía aquí
      // se retiró: repetía la barra de estado inferior y encima se quedaba
      // congelada con el recuento del arranque (marcaba 1 clave con 4 dadas de
      // alta). Ese sitio lo ocupan ahora el selector de modelo y el de
      // esfuerzo, que sí necesitan estar a mano al escribir la orden.
      // El desplegable de gobernanza nacía siempre en "Híbrido" porque nadie le
      // daba valor: con el motor en "Prioriza pago", el compositor decía una
      // cosa y la barra de estado la contraria. Un control que miente sobre el
      // estado actual es peor que no tenerlo.
      const govSel = this.container.querySelector<HTMLSelectElement>('#sel-gov-mode');
      if (govSel) {
      const gov = await this.core.getGovernance().catch(() => null);
        if (gov?.mode) govSel.value = gov.mode;
        govSel.dataset.committed = govSel.value;
      }
      await this.restoreSavedOrderModel();
      await this.refreshModelPickers();
    } catch {
      // El estado es informativo: su fallo no debe impedir escribir una orden.
    }
  }

  /**
   * Rellena el selector de modelo con los favoritos del router primero y el
   * resto después.
   */
  private async refreshModelPickers(): Promise<void> {
    if (!this.core) return;
    const sel = this.container.querySelector<HTMLSelectElement>('#sel-model');
    if (!sel) return;

    const [providers, plan, exec, audit, swarm, gov, extAgents, selection, extraRoles, swarmState, review] = await Promise.all([
      this.core.listProviders().catch(() => []),
      this.core.getPlanModel().catch(() => ({ provider: '', model: '' })),
      // ROLES-MODELO: un motor viejo sin estos handlers devuelve vacío —
      // los selectores quedan en "igual que la orden", que es justo lo que
      // ese motor haría (un solo pin para todo).
      this.core.getExecModel().catch(() => ({ provider: '', model: '' })),
      this.core.getAuditModel().catch(() => ({ provider: '', model: '' })),
      // ENJAMBRE: un motor viejo sin este handler devuelve vacío — queda en
      // Automático, que es justo lo que ese motor haría (sin conjunto fijo).
      this.core.getSwarmModels().catch(() => []),
      this.core.getGovernance().catch(() => null),
      // E5.08 — GOBIERNO ENCIMA: registro de agentes externos detectados.
      // Motor viejo → [] — solo catálogo, que es lo que ese motor despacha.
      this.core.getExternalAgents().catch(() => []),
      this.core.modelSelection ? this.core.modelSelection() : Promise.resolve([]),
      this.core.getRoleModels ? this.core.getRoleModels() : Promise.resolve([]),
      this.core.getSwarmEnabled ? this.core.getSwarmEnabled() : Promise.resolve({ enabled: true }),
      this.core.getComposerReview ? this.core.getComposerReview() : Promise.resolve(null),
    ]);
    // SOLO-LOCAL: el picker deja de ofrecer modelos de nube — el motor los
    // rechazaría al despachar; mostrarlos elegibles sería mentir.
    const localOnly = gov?.mode === 'local';

    // El bridge puede resolver una forma no-array ante un error de transporte:
    // sin la guardia, un refresh en vuelo revienta con `forEach` y deja la
    // lista a medio pintar.
    const providerList = Array.isArray(providers) ? providers : [];

    type Row = {
      provider: string;
      model: string;
      fav: boolean;
      free: boolean;
      ctx: number;
      available: boolean;
      enabledProvider: boolean;
      /** MODELO-LOCAL: el proveedor corre en esta máquina (Ollama), sin clave. */
      local: boolean;
      /** E5.08: agente externo (`agent:<cli>`) — suscripción del usuario, no API. */
      agent?: boolean;
      automaticAllowed?: boolean;
      /** Gratuidad por modelo declarada por el motor, independiente de la sesión CLI. */
      billingFree?: boolean;
      /** E5.08: etiqueta emitida por el motor, p.ej. «Claude Code (tu suscripción)». */
      label?: string;
      group?: string;
      manufacturer?: string;
      exe?: string;
      version?: string;
      session?: string;
      enumeration?: string;
      reason?: string;
      aclSignals?: string[];
      aclWriters?: string[];
      signature?: string;
      efforts?: string[];
      effort?: string;

    };
    const rows: Row[] = [];
    providerList.forEach((p) =>
      (Array.isArray(p.models) ? p.models : []).forEach((m) => {
        if (!m.name) return;
        // S4: este desplegable elige el modelo que va a ESCRIBIR la orden, así que
        // solo tienen sentido los que generan texto. Ofrecía `imagen-4.0`, `veo-3.1`,
        // `lyria-3`, los `rerank-*` y los de embeddings: el router los excluye solo,
        // pero fijar uno a mano aquí condenaba la orden sin decir por qué.
        // `text_gen` ausente (motor antiguo) se trata como «sí»: ante la duda se
        // muestra, que esconder un modelo bueno es peor que ofrecer uno inútil.
        const metadata = selection.find(r => r.provider === p.name && r.model === m.name);
        if ((metadata?.text_gen ?? m.text_gen) === false) return;
        rows.push({
          provider: p.name,
          model: m.name,
          fav: !!m.is_favorite,
          free: metadata?.is_free ?? !!m.is_free,
          ctx: m.context_window ?? 0,
          available: m.available !== false,
          enabledProvider: p.enabled !== false,
          local: p.local === true,
        });
      })
    );
    // E5.08 — GOBIERNO ENCIMA: los agentes externos detectados entran a los
    // pickers como filas más (`agent:<cli>|<cli>`), elegibles como ejecutor
    // (pins) y como miembros del enjambre. El motor ya impone la auditoría
    // cruzada por fabricante al despachar; aquí solo se les da la etiqueta
    // «(tu suscripción)». `local:false` los saca del modo Solo-local igual
    // que a la nube: son procesos de esta máquina pero consumen nube.
    rows.push(...externalModelRows(Array.isArray(extAgents) ? extAgents : []));
    for (const row of rows) {
      const metadata = selection.find(r => r.provider === row.provider && r.model === row.model);
      row.automaticAllowed = metadata?.allow_automatic !== false;
    }
    rows.sort((a, b) => Number(b.fav) - Number(a.fav) || a.model.localeCompare(b.model));
    const visibleRows = rows.filter(r => {
      const metadata = selection.find(m => m.provider === r.provider && m.model === r.model);
      return metadata?.show_in_selectors !== false && metadata?.text_gen !== false &&
        (localOnly ? r.local : gov?.mode === 'free' ? (metadata?.is_free ?? r.free) : true);
    });
    // T2d-D6: en «Solo gratis», un agente detectado sin ninguna fila gratuita
    // (Gemini con cuenta personal de Google, una CLI con clave de API…) no
    // desaparece en silencio: queda una fila suya deshabilitada con el motivo
    // que dio el motor en la etiqueta.
    const freeBlockedAgents = gov?.mode === 'free' && !localOnly
      ? rows.filter((r, i) => r.agent && rows.findIndex(o => o.provider === r.provider) === i &&
          !visibleRows.some(v => v.provider === r.provider) &&
          selection.find(m => m.provider === r.provider && m.model === r.model)?.show_in_selectors !== false)
      : [];
    const swarmEligible = (r: Row) => r.automaticAllowed !== false &&
      (localOnly ? r.local : gov?.mode === 'free' ? r.free : true);

    const options = (current: string, emptyLabel: string, role: string) => {
      // Pin persistido que el modo actual bloquea: se muestra deshabilitado en
      // vez de desaparecer — el motor sigue guardándolo y rechazándolo, y la
      // cabina no debe fingir que la orden quedó en "Automático".
      const currentRow = rows.find(r => `${r.provider}|${r.model}` === current);
      const currentMetadata = selection.find(r => `${r.provider}|${r.model}` === current);
      const blockedMode = currentMetadata?.text_gen === false ? 'capacidad de texto incompatible' : localOnly && !currentRow?.local ? 'Solo local' :
        gov?.mode === 'free' && currentRow?.free === false ? 'Solo gratis' : '';
      const blocked = blockedMode && current
        ? `<option value="${escapeAttribute(current)}" selected disabled>${esc(current)} · bloqueado por ${blockedMode}</option>`
        : '';
      const hiddenPin = !blocked && current && !visibleRows.some(r => `${r.provider}|${r.model}` === current)
        ? `<option value="${escapeAttribute(current)}" selected disabled>${esc(current)} · fijado a mano (fuera de la lista visible)</option>`
        : '';
      return `<option value="">${esc(emptyLabel)}</option>` +
        blocked + hiddenPin +
        visibleRows
          .map((r) => {
            const v = `${r.provider}|${r.model}`;
            const tag = r.fav ? '★ ' : '';
            const price = r.agent ? '' : r.free ? '' : ' · pago';
            const local = r.local ? ' · local' : '';
            // r3: el rol de auditor tampoco admite una CLI sin
            // protocolo (order_preflight.zig:20); la opción va deshabilitada y
            // explica el motivo. Codex y los modelos de nube quedan intactos.
            const roleBlocked = (role === 'audit' || role === 'second_audit') && MissionControlPanel.executorOnlyCli(r.provider);
            return `<option value="${escapeAttribute(v)}" ${v === current ? 'selected' : ''} ${!r.available || roleBlocked ? 'disabled' : ''}${roleBlocked ? ` title="${escapeAttribute(MissionControlPanel.cliRoleBlockedTitle)}"` : ''}>${tag}${esc(r.label ?? r.model)}${price}${local}</option>`;
          })
          .join('') +
        freeBlockedAgents
          .filter(r => `${r.provider}|${r.model}` !== current)
          .map(r => `<option value="${escapeAttribute(`${r.provider}|${r.model}`)}" disabled data-free-blocked="1">${esc(r.label ?? r.model)} · no entra en Solo gratis</option>`)
          .join('');
    };

    const fill = (el: HTMLSelectElement | null, current: string, emptyLabel: string) => {
      if (!el) return;
      el.innerHTML = options(current, emptyLabel, el.id === 'sel-model' ? 'plan' : el.id === 'sel-model-audit' ? 'audit' : 'exec');
      el.value = current;
      el.dataset.committed = current;
    };
    const mainValue = this.mainCliChoice && this.mainCliChoice === `${exec.provider}|${exec.model}` ? this.mainCliChoice : plan.provider ? `${plan.provider}|${plan.model}` : '';
    fill(sel, mainValue, 'Automático');
    fill(
      this.container.querySelector<HTMLSelectElement>('#sel-model-exec'),
      exec.provider ? `${exec.provider}|${exec.model}` : '',
      'Igual que la orden'
    );
    fill(
      this.container.querySelector<HTMLSelectElement>('#sel-model-audit'),
      audit.provider ? `${audit.provider}|${audit.model}` : '',
      'Automático (otro fabricante)'
    );

    // ENJAMBRE: lista checkbox con los mismos `rows` del catálogo — fuera de
    // la lista permitida no se puede elegir nada, por construcción. Un miembro
    // persistido que ya no esté en catálogo se muestra marcado como «fuera de
    // catálogo» para que el usuario vea la verdad en vez de una selección
    // fantasma. La lista se pinta en renderSwarmList (la llama
    // renderModelList, más abajo, cuando modelRows ya está asignado).
    this.swarmEnabled = swarmState.enabled;
    this.swarmSelection = swarm.map((m) => `${m.provider}|${m.model}`);
    // El motor manda en los miembros, no en el modo de la casilla: si el
    // usuario desmarcó «Automático» para elegir a mano mientras este refresh
    // estaba en vuelo, re-marcarla le escondería la lista a mitad del gesto.
    // Con conjunto persistido sí se fuerza manual (es el estado real).
    if (this.swarmSelection.length) this.swarmAuto = false;
    const catalog = new Set(rows.map((r) => `${r.provider}|${r.model}`));
    const visible = new Set(visibleRows.map((r) => `${r.provider}|${r.model}`));
    this.swarmExtras = this.swarmSelection.filter((v) => !catalog.has(v));
    // Miembros que existen en catálogo pero el modo Solo-local deja fuera del
    // reparto: siguen visibles, marcados como bloqueados — no desaparecen.
    this.swarmBlocked = this.swarmSelection.filter((v) => catalog.has(v) &&
      !swarmEligible(rows.find(r => `${r.provider}|${r.model}` === v)!));
    this.swarmPinnedHidden = rows.filter(r => this.swarmSelection.includes(`${r.provider}|${r.model}`) &&
      !visible.has(`${r.provider}|${r.model}`) && swarmEligible(r))
      .map(r => ({ value: `${r.provider}|${r.model}`, label: r.label ?? r.model, available: r.available }));
    const swarmHost = this.container.querySelector<HTMLElement>('#swarm-list');
    if (swarmHost) swarmHost.dataset.committed = JSON.stringify(this.swarmSelection);
    this.syncSwarmControls();

    this.nativeReview = review;
    this.extraRolePins = Object.fromEntries(extraRoles.map(r => [r.role, `${r.provider}|${r.model}`]));
    this.modelRows = visibleRows;
    this.freeBlockedRows = freeBlockedAgents.map(r => ({ provider: r.provider, model: r.model, label: r.label }));
    this.roleOptions = options;
    this.pinnedRoles = {
      plan: plan.provider ? `${plan.provider}|${plan.model}` : '',
      exec: exec.provider ? `${exec.provider}|${exec.model}` : '',
      audit: audit.provider ? `${audit.provider}|${audit.model}` : '',
    };
    this.renderRoleRows();
    this.updateModelChip();
    this.renderPinSummary();
    this.renderModelList();
    this.renderExternalDetail();
    void this.core.orderPreflight().then(check => this.showConfiguration(check)).catch(error => notice(String(error), 'error'));
    this.syncDeterministicAvailability(
      Boolean((plan.provider && plan.model) || (exec.provider && exec.model) || (audit.provider && audit.model))
    );
  }

  // --- PICKER-MODELO (estilo Devin) -------------------------------------------
  //
  // El panel plegable conserva los selects de siempre (mismos IDs/bindings);
  // lo nuevo es la lista buscable de la izquierda, el resumen del chip y el
  // grupo «Recientes». Nada de esto inventa estado: los pins se leen del motor
  // en refreshModelPickers y los recientes son solo un espejo local de lo que
  // el usuario ya fijó con éxito.

  private modelRows: Array<{
    provider: string;
    model: string;
    fav: boolean;
    free: boolean;
    ctx: number;
    available: boolean;
    enabledProvider: boolean;
    /** MODELO-LOCAL: proveedor de la máquina del usuario (Ollama). */
    local: boolean;
    /** E5.08: agente externo por suscripción (`agent:<cli>`). */
    agent?: boolean;
    automaticAllowed?: boolean;
    billingFree?: boolean;
    /** E5.08: etiqueta del motor («X (tu suscripción)»). */
    label?: string;
      group?: string;
      manufacturer?: string;
      exe?: string;
      version?: string;
      session?: string;
      enumeration?: string;
      reason?: string;
      aclSignals?: string[];
      aclWriters?: string[];
      signature?: string;
      efforts?: string[];
      effort?: string;
  }> = [];
  /** T2d-D6: agentes que «Solo gratis» deja fuera; se listan sin poder elegirse. */
  private freeBlockedRows: Array<{ provider: string; model: string; label?: string }> = [];
  private externalDetail = '';
  private nativeReview: { mode: string; label: string; pending_verdict: boolean } | null = null;
  private explicitRoleRows = new Set<string>();
  private mainCliChoice = '';
  private extraRolePins: Record<string, string> = {};
  private roleOptions: ((current: string, emptyLabel: string, role: string) => string) | null = null;

  private renderRoleRows(): void {
    const host = this.container.querySelector<HTMLElement>('#model-role-rows');
    if (!host) return;
    this.explicitRoleRows ??= new Set();
    const pins: Record<string, string> = { exec: this.pinnedRoles.exec, audit: this.pinnedRoles.audit, ...this.extraRolePins };
    for (const [role, value] of Object.entries(pins)) if (value && !(role === 'exec' && value === this.mainCliChoice)) this.explicitRoleRows.add(role);
    const labels: Record<string, string> = { exec: 'Ejecutor', audit: 'Auditor', second_audit: 'Segundo auditor', programmer: 'Programador', sidekick: 'Sidekick' };
    const hints: Record<string, string> = {
      exec: 'Ejecuta las tareas productoras.',
      audit: 'Revisa; nunca del mismo fabricante que quien produjo.',
      second_audit: 'Alterna con el auditor; si falta, el motor clona una auditoría.',
      programmer: 'Tareas programar, programar_c, _cpp y _zig.',
      sidekick: 'Tareas investigar, resumir y documentar.',
    };
    host.innerHTML = [...this.explicitRoleRows].map(role => `<div class="model-role-row model-role-grid" data-role-row="${escapeAttribute(role)}">
      <label for="sel-model-${escapeAttribute(role)}">${esc(labels[role])}</label>
      <select class="select" id="sel-model-${escapeAttribute(role)}" data-role="${escapeAttribute(role)}" data-committed="${escapeAttribute(pins[role] || '')}" aria-label="${esc(labels[role])}">${this.roleOptions?.(pins[role] || '', 'Automático', role) ?? '<option value="">Automático</option>'}</select>
      <button class="btn btn--sm" data-remove-role="${escapeAttribute(role)}" aria-label="Quitar ${esc(labels[role])}" type="button">Quitar</button>
      <div class="model-role-hint">${esc(hints[role] ?? '')}</div></div>`).join('');
    const choice = this.container.querySelector<HTMLSelectElement>('#sel-add-role');
    if (choice) {
      for (const option of choice.options) option.disabled = this.explicitRoleRows.has(option.value);
      if (this.explicitRoleRows.has(choice.value)) choice.value = [...choice.options].find(o => !o.disabled)?.value ?? '';
    }
    const add = this.container.querySelector<HTMLButtonElement>('#btn-add-role');
    if (add) add.disabled = this.explicitRoleRows.size >= 5;
  }

  private async applyRoleModel(role: string, value: string): Promise<void> {
    if (!this.core) return;
    const [provider = '', model = ''] = value.split('|');
    if ((role === 'audit' || role === 'second_audit') && MissionControlPanel.executorOnlyCli(provider)) {
      await this.refreshModelPickers();
      return;
    }
    try {
      if (role === 'exec') await this.core.setExecModel(provider, model);
      else if (role === 'audit') await this.core.setAuditModel(provider, model);
      else await this.core.setRoleModel(role, provider, model);
    } finally {
      await this.refreshModelPickers();
    }
  }

  private pinnedRoles = { plan: '', exec: '', audit: '' };
  /** ENJAMBRE: miembros fijados (valores "provider|model") y modo automático. */
  private swarmSelection: string[] = [];
  private swarmAuto = true;
  private swarmEnabled = true;
  /** Miembros persistidos que ya no están en el catálogo (verdad, no fantasma). */
  private swarmExtras: string[] = [];
  /** En modo Solo-local: miembros persistidos que el modo bloquea (nube). */
  private swarmBlocked: string[] = [];
  private swarmPinnedHidden: Array<{ value: string; label: string; available: boolean }> = [];
  private modelQuery = '';
  private modelPickerOpen = false;
  private modesPickerOpen = false;
  /** Cierre del popover de Modos: en `document` solo mientras está abierto. */
  private modesPickerDismissKey: ((event: KeyboardEvent) => void) | null = null;
  private modesPickerDismissPointer: ((event: MouseEvent) => void) | null = null;
  /** Cierre del popover: viven en `document` SOLO mientras el selector está abierto. */
  private modelPickerDismissKey: ((event: KeyboardEvent) => void) | null = null;
  private modelPickerDismissPointer: ((event: MouseEvent) => void) | null = null;
  private readCabinDisclosure(): Record<string, boolean> {
    try {
      const value: unknown = JSON.parse(window.localStorage.getItem('devagents.cabin.disclosure.v1') || '{}');
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Formato inválido');
      const entries = Object.entries(value);
      if (entries.length > 256 || entries.some(([key, state]) =>
        typeof state !== 'boolean' || key.length > 256 ||
        !(key === 'advanced' || key === 'colmena' || key === 'favorites' || key === 'recent' || key.startsWith('provider:')))) {
        throw new Error('Preferencias de grupos inválidas');
      }
      return Object.fromEntries(entries);
    } catch (error) {
      notice(`No se pudieron leer las preferencias del selector: ${String(error)}`, 'error');
      return {};
    }
  }

  private writeCabinDisclosure(value: Record<string, boolean>): void {
    try {
      window.localStorage.setItem('devagents.cabin.disclosure.v1', JSON.stringify(value));
    } catch (error) {
      notice(`No se pudieron guardar las preferencias del selector: ${String(error)}`, 'error');
    }
  }
  private visionProbeBusy = false;
  private visionProbeText = 'Visión sin medir. Elige un modelo y pulsa Medir visión.';

  private renderVisionProbeStatus(): void {
    const button = this.container.querySelector<HTMLButtonElement>('#btn-vision-probe');
    if (button) {
      button.disabled = this.visionProbeBusy;
      button.textContent = this.visionProbeBusy ? 'Midiendo visión…' : 'Medir visión';
    }
    const status = this.container.querySelector<HTMLElement>('#vision-probe-status');
    if (status) status.textContent = this.visionProbeText;
  }

  /** Nunca sondea al cambiar el selector: solo el clic explícito llama al motor. */
  private async probeSelectedVision(): Promise<void> {
    if (this.visionProbeBusy) return;
    const pin = this.pinnedRoles.exec || this.pinnedRoles.plan;
    const [provider = '', model = ''] = pin.split('|');
    if (!provider || !model) {
      this.visionProbeText = 'Visión sin medir. Elige el ejecutor o el modelo de la orden.';
      this.renderVisionProbeStatus();
      return;
    }
    if (!this.core) {
      this.visionProbeText = 'Visión sin medir: el puente con el motor no está disponible.';
      this.renderVisionProbeStatus();
      return;
    }
    const label = `${provider} · ${model}`;
    this.visionProbeBusy = true;
    this.visionProbeText = `${label}: Midiendo visión…`;
    this.renderVisionProbeStatus();
    try {
      const result = await this.core.visionProbe(provider, model);
      if (result.provider !== provider || result.model !== model) throw new Error('La respuesta no corresponde al modelo solicitado.');
      const measured = result.cap_vision_status === 'yes' ? 'Visión medida: sí'
        : result.cap_vision_status === 'no' ? 'Visión medida: no' : 'Visión sin medir';
      this.visionProbeText = `${label}: ${measured}${result.reason ? ` — ${result.reason}` : result.cap_vision_status === 'not_probed' ? ` (${result.status})` : ''}`;
    } catch (error) {
      this.visionProbeText = `${label}: Visión sin medir — ${String(error)}`;
    } finally {
      this.visionProbeBusy = false;
      this.renderVisionProbeStatus();
    }
  }

  private recentModels(): string[] {
    try {
      const raw = JSON.parse(window.localStorage.getItem('devagents.recentModels') || '[]');
      return Array.isArray(raw) ? raw.filter((v) => typeof v === 'string') : [];
    } catch {
      return [];
    }
  }

  private pushRecentModel(value: string): void {
    if (!value) return;
    const list = [value, ...this.recentModels().filter((v) => v !== value)].slice(0, 8);
    storageSet('devagents.recentModels', JSON.stringify(list));
  }

  private shortModel(value: string): string {
    // E5.08: un pin agent:* muestra la etiqueta del motor («Codex (tu
    // suscripción)»), no el cli_id a secas que vendría del split.
    const row = (this.modelRows ?? []).find((r) => `${r.provider}|${r.model}` === value);
    return row?.label ?? (value.split('|')[1] || value);
  }

  /**
   * E1.17/F4: toast de coste al fijar un modelo a mitad de conversación.
   * Solo avisa cuando el modelo es de pago — que es cuando cambiar la
   * selección cambia lo que se gasta. Fuera de catálogo cuenta como de pago,
   * igual que asume el motor al repartir.
   */
  private toastCostIfMidChat(value: string): void {
    if (this.orderId <= 0 || !value) return;
    const row = (this.modelRows ?? []).find((r) => `${r.provider}|${r.model}` === value);
    if (row?.free || (row?.agent && row.session !== 'api_key')) return;
    notice(
      `${this.shortModel(value)} no está catalogado como gratuito: las próximas llamadas de esta conversación consumen presupuesto de pago autorizado.`,
      'info'
    );
  }

  /**
   * QA-B 2c: selector de cuenta en el compositor. Visible solo si la CLI que
   * va a trabajar (ejecutor o modelo de la orden: Codex o Claude Code) tiene
   * cuentas; vale para Directo, Orquestado y Colmena (el motor rota igual en
   * los tres). Lee y guarda con la misma API que Configuración › Cuentas.
   */
  private cliAccountRefresh = 0;
  private async refreshCliAccountPicker(): Promise<void> {
    const select = this.container.querySelector<HTMLSelectElement>('#composer-cli-account');
    if (!select) return;
    const provider = (this.pinnedRoles.exec || this.pinnedRoles.plan).split('|')[0] ?? '';
    const cli = provider === 'agent:codex' ? 'codex' : provider === 'agent:claude-code' ? 'claude-code' : '';
    const ticket = (this.cliAccountRefresh = (this.cliAccountRefresh || 0) + 1);
    if (!cli || !this.core || typeof this.core.getCliAccounts !== 'function') {
      select.hidden = true;
      return;
    }
    let entry: { cli: string; display: string; selected: string | null; accounts: Array<{ id: string; label: string }> } | undefined;
    try {
      entry = (await this.core.getCliAccounts()).clis.find((c) => c.cli === cli);
    } catch (e) {
      select.hidden = true;
      select.title = `No se pudieron leer las cuentas: ${String(e)}`;
      return;
    }
    if (ticket !== this.cliAccountRefresh) return;
    if (!entry || entry.accounts.length === 0) {
      select.hidden = true;
      return;
    }
    const chosen = entry.selected ?? '';
    select.innerHTML = [`<option value="">${esc(entry.display)}: login del sistema</option>`]
      .concat(entry.accounts.map((acc) => `<option value="${escapeAttribute(acc.id)}">${esc(entry!.display)}: ${esc(acc.label)}</option>`))
      .join('');
    select.value = chosen;
    select.dataset.cli = cli;
    select.hidden = false;
  }

  /** El chip resume lo que el motor tiene fijado, no lo que el usuario miró. */
  private updateModelChip(): void {
    void this.refreshCliAccountPicker();
    const label = this.container.querySelector<HTMLElement>('#model-chip-label');
    if (!label) return;
    const { plan, exec, audit } = this.pinnedRoles;
    const swarm = this.swarmSelection.length;
    if (this.directMode && !plan && !exec) {
      label.textContent = 'Automático · Directo';
      label.title = 'Directo: responde el primer modelo apto con herramientas; elige uno para usar solo ese';
      return;
    }
    if (!plan && !exec && !audit && !swarm) {
      // Maqueta v2 (composerHTML): «Automático · N en colmena».
      label.textContent = this.swarmEnabled === false ? 'Automático' : 'Automático · en colmena';
      label.title = 'El router elige por tarea según gobernanza y salud';
      return;
    }
    if (!plan && !exec && !audit && swarm && this.swarmEnabled !== false) {
      label.textContent = `Automático · ${swarm} en colmena`;
      label.title = `El router planifica; ${swarm} modelos se reparten las tareas en paralelo`;
      return;
    }
    // con más de un rol fijado el chip NOMBRA cada rol (p. ej.
    // «Planificador: Sol · Ejecutor: Claude Code»), que es como se ve que la
    // CLI quedó de ejecutor y el modelo de la orden intacto. Un único modelo
    // de la orden conserva la forma corta de siempre.
    const roles = (plan ? 1 : 0) + (exec ? 1 : 0) + (audit ? 1 : 0) + (swarm ? 1 : 0);
    // 9-nov: en Directo no hay planificador ni ejecutor: un solo modelo (o una
    // CLI) responde. El chip decía «Ejecutor: Claude Code…» al elegir una CLI.
    if (this.directMode && (plan || exec) && !audit && !swarm) {
      const only = exec || plan;
      label.textContent = this.shortModel(only);
      label.title = `Directo: ${only}`;
      return;
    }
    if (roles === 1 && plan) {
      label.textContent = this.shortModel(plan);
      label.title = `Orden: ${plan}`;
      return;
    }
    const parts: string[] = [];
    if (plan) parts.push(`Planificador: ${this.shortModel(plan)}`);
    if (exec) parts.push(`Ejecutor: ${this.shortModel(exec)}`);
    if (audit) parts.push(`Auditor: ${this.shortModel(audit)}`);
    if (swarm) parts.push(`Enjambre: ${swarm}`);
    label.textContent = parts.join(' · ');
    label.title = [
      plan && `Orden: ${plan}`,
      exec && `Ejecutor: ${exec}`,
      audit && `Auditor: ${audit}`,
      swarm && `Enjambre: ${this.swarmSelection.join(', ')}`,
    ]
      .filter(Boolean)
      .join('\n');
  }

  private toggleModelPicker(open?: boolean): void {
    const next = open ?? !this.modelPickerOpen;
    this.setModelPickerOpen(next, !next);
  }

  /** Cierra el selector sin robar el foco (clic fuera, envío o plan pendiente). */
  private dismissModelPicker(): void {
    if (this.modelPickerOpen) this.setModelPickerOpen(false, false);
  }

  /**
 * (d): las ventanas de Modos y Modelo se ajustan al sitio que hay
   * de verdad. La maqueta las dibuja sobre el compositor con 440 y 760 px,
   * nunca más anchas que la pantalla; antes Modelo tomaba el ancho del
   * compositor (a 1180 px se apilaba en una columna estrecha) y ninguna sabía
   * cuánto alto quedaba encima (a 700 px se salía por arriba).
   */
  private fitComposerPopups(): void {
    const composer = this.container.querySelector<HTMLElement>('#mission-composer');
    if (!composer || typeof window === 'undefined') return;
    const rect = composer.getBoundingClientRect();
    const room = Math.max(200, Math.floor(rect.top - 12));
    const wide = Math.max(280, Math.floor(window.innerWidth - rect.left - 12));
    const model = this.container.querySelector<HTMLElement>('#model-picker');
    if (model) {
      model.style.right = 'auto';
      model.style.width = `${Math.min(760, wide)}px`;
      // Alto fijo como la maqueta (.mp{height:600px}), recortado al sitio que hay:
      // así la lista se desplaza dentro y «Volver a detectar» queda siempre visible.
      model.style.height = `${Math.min(600, room)}px`;
      model.style.maxHeight = `${Math.min(600, room)}px`;
    }
    const modes = this.container.querySelector<HTMLElement>('#modes-picker');
    if (modes) {
      modes.style.width = `${Math.min(440, wide)}px`;
      modes.style.maxHeight = `${Math.min(600, room)}px`;
    }
    if (!this.popupResizeBound) {
      this.popupResizeBound = true;
      window.addEventListener('resize', () => {
        if (this.modelPickerOpen || this.modesPickerOpen) this.fitComposerPopups();
      });
    }
  }
  private popupResizeBound = false;

  private setModelPickerOpen(open: boolean, focusChip: boolean): void {
    if (open && this.modesPickerOpen) this.setModesPickerOpen(false, false);
    this.modelPickerOpen = open;
    const pop = this.container.querySelector<HTMLElement>('#model-picker');
    if (pop) pop.style.display = open ? 'flex' : 'none';
    this.container.querySelector('#btn-model-picker')?.setAttribute('aria-expanded', String(open));
    if (open) {
      this.fitComposerPopups();
      this.renderModelList();
      // Si el catálogo aún no llegó, pedirlo: abrir el panel sobre una lista
      // vacía se leía como «no hay modelos» cuando era «todavía no cargaron».
      if (!this.modelRows.length) void this.refreshModelPickers();
      this.bindModelPickerDismiss();
      window.setTimeout(() => this.container.querySelector<HTMLInputElement>('#model-search')?.focus(), 0);
    } else {
      this.unbindModelPickerDismiss();
      if (focusChip) this.container.querySelector<HTMLElement>('#btn-model-picker')?.focus();
    }
  }

  /**
   * Mientras el selector está abierto el cierre por Escape y clic fuera escucha
   * en `document`, no en el contenedor: si el foco cae fuera del compositor
   * (p. ej. en `body` tras repintar el plan), un listener del contenedor nunca
   * ve el Escape y el panel se queda encima tapando «Aprobar y ejecutar». Se
   * retiran al cerrar; el teclado de flechas sigue en el propio panel.
   */
  private bindModelPickerDismiss(): void {
    if (this.modelPickerDismissKey) return;
    this.modelPickerDismissKey = (event) => {
      if (!this.modelPickerOpen || event.key !== 'Escape') return;
      const search = this.container.querySelector<HTMLInputElement>('#model-search');
      const inSearch = !!search && (event.target === search || search.contains(event.target as Node));
      if (inSearch && this.modelQuery) {
        // Escape en el buscador limpia el texto si lo hay; si ya está vacío, cierra.
        if (search) search.value = '';
        this.modelQuery = '';
        this.renderModelList();
      } else {
        this.setModelPickerOpen(false, true);
      }
      event.preventDefault();
      event.stopPropagation();
    };
    this.modelPickerDismissPointer = (event) => {
      if (!this.modelPickerOpen) return;
      const target = event.target as Node;
      const pop = this.container.querySelector<HTMLElement>('#model-picker');
      const chip = this.container.querySelector<HTMLElement>('#btn-model-picker');
      if (pop && !pop.contains(target) && chip && !chip.contains(target)) this.dismissModelPicker();
    };
    document.addEventListener('keydown', this.modelPickerDismissKey, true);
    document.addEventListener('mousedown', this.modelPickerDismissPointer, true);
  }

  private unbindModelPickerDismiss(): void {
    if (this.modelPickerDismissKey) {
      document.removeEventListener('keydown', this.modelPickerDismissKey, true);
      this.modelPickerDismissKey = null;
    }
    if (this.modelPickerDismissPointer) {
      document.removeEventListener('mousedown', this.modelPickerDismissPointer, true);
      this.modelPickerDismissPointer = null;
    }
  }

  // --- Ventana «Modos» (006a) ----------------------------------------
  // Los controles reales siguen siendo los de siempre (#chk-swarm-enabled,
  // #wait-plan-approval, #sel-perm-mode, #sel-gov-mode, #sel-best-of-n,
  // #num-agentic y #sel-effort); esta ventana solo los presenta juntos y
  // escribe sobre ellos despachando `change`, para no duplicar estado.

  private toggleModesPicker(open?: boolean): void {
    const next = open ?? !this.modesPickerOpen;
    this.setModesPickerOpen(next, !next);
  }

  private dismissModesPicker(): void {
    if (this.modesPickerOpen) this.setModesPickerOpen(false, false);
  }

  private setModesPickerOpen(open: boolean, focusChip: boolean): void {
    if (open && this.modelPickerOpen) this.setModelPickerOpen(false, false);
    this.modesPickerOpen = open;
    const pop = this.container.querySelector<HTMLElement>('#modes-picker');
    if (pop) pop.style.display = open ? 'flex' : 'none';
    this.container.querySelector('#btn-modes-picker')?.setAttribute('aria-expanded', String(open));
    if (open) {
      this.fitComposerPopups();
      const paid = document.getElementById('status-paid-budget')?.textContent?.trim() ?? '';
      const paidText = this.container.querySelector<HTMLElement>('#modes-paid-text');
      if (paidText) paidText.textContent = paid || 'Pago: comprobando…';
      this.syncSegmented('sel-effort');
      this.bindModesPickerDismiss();
    } else {
      this.unbindModesPickerDismiss();
      if (focusChip) this.container.querySelector<HTMLElement>('#btn-modes-picker')?.focus();
    }
  }

  private bindModesPickerDismiss(): void {
    if (this.modesPickerDismissKey) return;
    this.modesPickerDismissKey = (event) => {
      if (!this.modesPickerOpen || event.key !== 'Escape') return;
      this.setModesPickerOpen(false, true);
      event.preventDefault();
      event.stopPropagation();
    };
    this.modesPickerDismissPointer = (event) => {
      if (!this.modesPickerOpen) return;
      const target = event.target as Node;
      const pop = this.container.querySelector<HTMLElement>('#modes-picker');
      const chip = this.container.querySelector<HTMLElement>('#btn-modes-picker');
      if (pop && !pop.contains(target) && chip && !chip.contains(target)) this.dismissModesPicker();
    };
    document.addEventListener('keydown', this.modesPickerDismissKey, true);
    document.addEventListener('mousedown', this.modesPickerDismissPointer, true);
  }

  private unbindModesPickerDismiss(): void {
    if (this.modesPickerDismissKey) {
      document.removeEventListener('keydown', this.modesPickerDismissKey, true);
      this.modesPickerDismissKey = null;
    }
    if (this.modesPickerDismissPointer) {
      document.removeEventListener('mousedown', this.modesPickerDismissPointer, true);
      this.modesPickerDismissPointer = null;
    }
  }

  /** Presenta un <select> real como control segmentado de botones. */
  private segmentedHtml(
    selectId: string,
    options: ReadonlyArray<readonly [value: string, label: string, risk?: boolean]>
  ): string {
    return `<div class="seg" data-segmented="${escapeAttribute(selectId)}" role="group">${options
      .map(([value, label, risk]) =>
        `<button type="button" class="seg__btn${risk ? ' seg__btn--risk' : ''}" data-value="${escapeAttribute(value)}" aria-pressed="false">${esc(label)}</button>`
      )
      .join('')}</div>`;
  }

  private syncSegmented(selectId: string): void {
    const select = this.container.querySelector<HTMLSelectElement>(`#${selectId}`);
    const group = this.container.querySelector<HTMLElement>(`[data-segmented="${selectId}"]`);
    if (!select || !group) return;
    group.querySelectorAll<HTMLButtonElement>('button[data-value]').forEach((button) => {
      const active = button.dataset.value === select.value;
      button.classList.toggle('is-active', active);
      button.setAttribute('aria-pressed', String(active));
    });
  }

  /**
   * El segmentado escribe el select y despacha `change`, y escucha el change
   * del select para repintar el botón activo cuando el valor cambia por otra
   * vía (/plan, el motor, etc.).
   */
  private bindSegmented(selectId: string): void {
    const select = this.container.querySelector<HTMLSelectElement>(`#${selectId}`);
    const group = this.container.querySelector<HTMLElement>(`[data-segmented="${selectId}"]`);
    if (!select || !group) return;
    this.syncSegmented(selectId);
    select.addEventListener('change', () => {
      this.syncSegmented(selectId);
      this.renderModeChips();
    });
    group.addEventListener('click', (event) => {
      const button = (event.target as HTMLElement).closest<HTMLButtonElement>('button[data-value]');
      if (!button || button.disabled || select.value === button.dataset.value) return;
      select.value = button.dataset.value!;
      select.dispatchEvent(new Event('change', { bubbles: true }));
      this.syncSegmented(selectId);
    });
  }

  /** Forma de trabajar: Orquestado = casilla apagada; Colmena = encendida. */
  private bindModeWays(): void {
    const root = this.container.querySelector<HTMLElement>('#modes-picker');
    if (!root) return;
    // «Enjambre activo» (ventana Modelo) es el mismo interruptor que Colmena:
    // encenderlo desde allí saca de Directo.
    this.container.querySelector<HTMLInputElement>('#chk-swarm-enabled')?.addEventListener('change', (event) => {
      if (!(event.target as HTMLInputElement).checked || !this.directMode) return;
      this.setDirectMode(false);
      saveWorkMode('colmena');
      this.syncModesPanel();
    });
    root.querySelectorAll<HTMLButtonElement>('[data-way]').forEach((button) => {
      button.addEventListener('click', () => {
        if (button.disabled) return;
        const way = button.dataset.way as WorkMode;
        this.setDirectMode(way === 'directo' || way === 'devagents', way === 'devagents');
        saveWorkMode(way);
        if (way === 'directo' || way === 'devagents') {
          this.syncModesPanel();
          return;
        }
        const checkbox = this.container.querySelector<HTMLInputElement>('#chk-swarm-enabled');
        if (!checkbox) return;
        const enabled = way === 'colmena';
        if (checkbox.checked !== enabled) {
          checkbox.checked = enabled;
          checkbox.dispatchEvent(new Event('change', { bubbles: true }));
        }
        this.syncModesPanel();
      });
    });
  }

  /** el texto del compositor dice lo que pasará con la orden. */
  private syncComposerPlaceholder(): void {
    const input = this.container.querySelector<HTMLTextAreaElement>('#mission-composer-input');
    if (!input) return;
    input.placeholder = this.delegateMode
      ? 'Escribe lo que necesites: el modelo responde y, si hay partes independientes, las delega en paralelo. (Enter para enviar, Shift+Enter para salto de línea)'
      : this.directMode
      ? 'Escribe lo que necesites: el modelo responde y trabaja en tu proyecto. (Enter para enviar, Shift+Enter para salto de línea)'
      : 'Describe tu orden. El agente la planifica, te enseña el plan y la ejecuta. (Enter para enviar, Shift+Enter para salto de línea)';
  }

  /** lleva la Forma de trabajar al motor; si lo rechaza, vuelve. */
  private setDirectMode(enabled: boolean, delegate = false): void {
    const wantDelegate = enabled && delegate;
    if (this.directMode === enabled && this.delegateMode === wantDelegate) return;
    const before = { direct: this.directMode, delegate: this.delegateMode };
    this.directMode = enabled;
    this.delegateMode = wantDelegate;
    this.updateModelChip();
    this.renderPinSummary();
    this.syncComposerPlaceholder();
    if (this.phase === 'idle') this.renderBody();
    if (typeof this.core?.setDirect !== 'function') return;
    void this.core.setDirect(enabled, wantDelegate).catch((error: unknown) => {
      this.directMode = before.direct;
      this.delegateMode = before.delegate;
      this.syncModesPanel();
      this.updateModelChip();
      this.renderPinSummary();
      notice(`No se pudo cambiar la forma de trabajar: ${String(error)}`, 'error');
    });
  }

  /** Refleja la casilla real y los selects en la ventana de Modos. */
  private syncModesPanel(): void {
    const enabled = this.container.querySelector<HTMLInputElement>('#chk-swarm-enabled');
    const hive = enabled ? enabled.checked : true;
    // QA primerizo (10-nov): en Directo «Enjambre activo» salía ENCENDIDO por
    // defecto (lo que quedara de Colmena) y contradecía el modo. Se muestra
    // apagado sin emitir `change`; encenderlo sigue llevando a Colmena y los
    // botones de Modos fijan el valor al salir de Directo.
    if (enabled) {
      if (this.directMode && enabled.checked) enabled.checked = false;
      const hint = enabled.closest?.('label')?.querySelector?.('small');
      if (hint) hint.textContent = this.directMode
        ? 'Directo usa un solo modelo. Enciéndelo para pasar a Colmena.'
        : 'El mismo interruptor que «Colmena» en Modos.';
    }
    this.container.querySelector<HTMLElement>('#modes-picker')
      ?.querySelectorAll<HTMLElement>('[data-way]')
      .forEach((button) => {
        const way = button.dataset?.way;
        if (!way) return;
        const active = way === (this.delegateMode ? 'devagents' : this.directMode ? 'directo' : hive ? 'colmena' : 'orquestado');
        button.classList.toggle('is-active', active);
        button.setAttribute('aria-pressed', String(active));
      });
    for (const id of ['sel-perm-mode', 'sel-gov-mode', 'sel-best-of-n', 'sel-effort']) this.syncSegmented(id);
    this.renderModeChips();
  }

  /**
   * Chips de los modos activos junto a los botones. Cada × devuelve SU
   * control real a su valor por defecto despachando `change`, que es lo que
   * escuchan los bindings de siempre.
   */
  private renderModeChips(): void {
    const host = this.container.querySelector<HTMLElement>('#composer-mode-chips');
    if (!host) return;
    const enabled = this.container.querySelector<HTMLInputElement>('#chk-swarm-enabled');
    const plan = this.container.querySelector<HTMLInputElement>('#wait-plan-approval');
    const perm = this.container.querySelector<HTMLSelectElement>('#sel-perm-mode');
    const bon = this.container.querySelector<HTMLSelectElement>('#sel-best-of-n');
    const steps = this.container.querySelector<HTMLInputElement>('#num-agentic');
    const effort = this.container.querySelector<HTMLSelectElement>('#sel-effort');
    const chips: string[] = [];
    const add = (key: string, label: string, risk = false, omitReset = false): void => {
      chips.push(
        `<span class="mode-chip${risk ? ' mode-chip--risk' : ''}">${esc(label)}` +
        (omitReset
          ? ''
          : `<button class="mode-chip__x" type="button" data-reset="${key}" title="Quitar" aria-label="Quitar ${escapeAttribute(label)}">×</button>`) +
        `</span>`
      );
    };
    if (this.delegateMode) add('way', 'DevAgents', false, true);
    else if (this.directMode) add('way', 'Directo', false, true);
    else if (enabled?.checked) add('way', 'Colmena');
    else add('way', 'Orquestado', false, true);
    if (plan?.checked) add('plan', 'Aprobar plan');
    if (this.container.querySelector<HTMLInputElement>('#chk-deterministic')?.checked) add('norb', 'Sin respaldo');
    const permLabels: Record<string, string> = {
      accept_edits: 'Aceptar ediciones',
      plan: 'Plan',
      autonomous: 'Auto',
      bypass: 'Omitir permisos',
    };
    const permLabel = perm ? permLabels[perm.value] : undefined;
    if (permLabel) add('perm', permLabel, perm!.value === 'autonomous' || perm!.value === 'bypass');
    const bonValue = Number(bon?.value ?? 0);
    if (bonValue > 0) add('bon', `Mejor de ${bonValue}`);
    const stepsValue = Math.max(1, Math.trunc(Number(steps?.value) || 1));
    if (stepsValue > 1) add('steps', `${stepsValue} pasos`);
    const effortLabels: Record<string, string> = { low: 'bajo', medium: 'medio', high: 'alto' };
    const effortLabel = effort ? effortLabels[effort.value] : undefined;
    if (effortLabel) add('effort', `Esfuerzo ${effortLabel}`);
    host.innerHTML = chips.join('');
  }

  private resetMode(key: string): void {
    const change = (element: HTMLInputElement | HTMLSelectElement | null, value: string | boolean): void => {
      if (!element) return;
      if (typeof value === 'boolean') (element as HTMLInputElement).checked = value;
      else element.value = value;
      element.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (key === 'way') change(this.container.querySelector<HTMLInputElement>('#chk-swarm-enabled'), false);
    else if (key === 'plan') change(this.container.querySelector<HTMLInputElement>('#wait-plan-approval'), false);
    else if (key === 'norb') change(this.container.querySelector<HTMLInputElement>('#chk-deterministic'), false);
    else if (key === 'perm') change(this.container.querySelector<HTMLSelectElement>('#sel-perm-mode'), 'normal');
    else if (key === 'bon') change(this.container.querySelector<HTMLSelectElement>('#sel-best-of-n'), '0');
    else if (key === 'steps') change(this.container.querySelector<HTMLInputElement>('#num-agentic'), '1');
    else if (key === 'effort') change(this.container.querySelector<HTMLSelectElement>('#sel-effort'), '');
    this.syncModesPanel();
  }

  /** Pinta la lista agrupada: Favoritos, Recientes y un <details> por proveedor. */
  private renderModelList(): void {
    const host = this.container.querySelector<HTMLElement>('#model-list');
    if (!host) return;
    const q = this.modelQuery.trim().toLowerCase();
    const match = (r: (typeof this.modelRows)[number]) =>
      !q ||
      r.model.toLowerCase().includes(q) ||
      r.provider.toLowerCase().includes(q) ||
      (r.label ?? '').toLowerCase().includes(q);
    const rows = this.modelRows.filter(match);
    const current = this.mainCliChoice || this.pinnedRoles.plan;
    const preferences = this.readCabinDisclosure();

    const item = (r: (typeof this.modelRows)[number]) => {
      const v = `${r.provider}|${r.model}`;
      const ctx = r.ctx > 0 ? `<span class="model-item__ctx">${Math.round(r.ctx / 1024)}k ctx</span>` : '';
      const tags = [
        r.fav ? '<span class="model-tag model-tag--fav">&#9733;</span>' : '',
        r.agent
          ? `<span class="model-tag">${esc(r.billingFree ? 'Gratis' : r.session === 'suscripcion' ? 'Suscripción' : r.session === 'api_key' ? 'API bloqueada' : 'Sesión no confirmada')}</span>`
          : r.free
            ? '<span class="model-tag model-tag--free">Gratis</span>'
            : '<span class="model-tag">Pago</span>',
        r.local ? '<span class="model-tag">Local</span>' : '',
        r.available || r.agent ? '' : '<span class="model-tag model-tag--off">caído</span>',
      ].join('');
      return `<button type="button" tabindex="-1" class="model-item ${v === current ? 'is-active' : ''}" data-val="${escapeAttribute(v)}" aria-pressed="${v === current}"
                   title="${esc(r.provider)} / ${escapeAttribute(r.model)}">
        <span class="model-item__name">${esc(r.label ?? r.model)}</span>${ctx}${tags}
      </button>`;
    };

    let groupIndex = 0;
    const group = (key: string, title: string, list: typeof rows) => {
      const listId = `model-group-options-${groupIndex++}`;
      const open = !!q || (preferences[key] ?? key === 'favorites');
      return (
      list.length
        ? `<details class="model-group" data-group="${escapeAttribute(key)}" ${open ? 'open' : ''}>
             <summary tabindex="-1" aria-expanded="${open}" aria-controls="${listId}">${esc(title)} <span class="model-group__count">${list.length}</span></summary>
             <div id="${listId}">${list.map(item).join('')}</div>
           </details>`
        : '');
    };

    const recent = this.recentModels()
      .map((v) => rows.find((r) => `${r.provider}|${r.model}` === v))
      .filter((r): r is (typeof rows)[number] => !!r);
    const favs = rows.filter((r) => r.fav);
    const recentWithoutFavs = recent.filter((r) => !r.fav);
    const rest = rows.filter((r) => !r.fav && !recent.includes(r));
    const byProvider = new Map<string, typeof rows>();
    rest.forEach((r) => {
      const arr = byProvider.get(r.group ?? r.provider) ?? [];
      arr.push(r);
      byProvider.set(r.group ?? r.provider, arr);
    });

    host.innerHTML =
      `<button type="button" tabindex="-1" class="model-item ${current ? '' : 'is-active'}" data-val="" aria-pressed="${!current}"><span class="model-item__name">Automático</span></button>` +
      (rows.length === 0
        ? `<div class="model-empty">${
            this.modelQuery
              ? `Sin resultados para «${esc(this.modelQuery)}»`
              : 'Cargando catálogo de modelos&#8230;'
          }</div>`
        : '') +
      group('favorites', 'Favoritos', favs) +
      group('recent', 'Recientes', recentWithoutFavs) +
      [...byProvider.entries()]
        .sort(([a], [b]) => a.localeCompare(b))
        .map(([p, list]) => group(`provider:${p}`, p, list))
        .join('') +
      this.freeBlockedGroup(q);

    host.querySelectorAll<HTMLDetailsElement>('.model-group').forEach((details) => {
      let previous = details.open;
      details.addEventListener('toggle', () => {
        details.querySelector('summary')?.setAttribute('aria-expanded', String(details.open));
        this.syncModelListFocus();
        if (details.open === previous) return;
        previous = details.open;
        if (!q && details.isConnected && !this.modelQuery.trim()) {
          const saved = this.readCabinDisclosure();
          saved[details.dataset.group!] = details.open;
          this.writeCabinDisclosure(saved);
        }
        this.syncGroupButton();
      });
    });
    host.querySelectorAll<HTMLElement>('summary, .model-item').forEach(el => {
      el.addEventListener('focus', () => this.syncModelListFocus(el));
    });
    this.syncModelListFocus();
    this.syncGroupButton();

    host.querySelectorAll<HTMLElement>('.model-item').forEach((el) => {
      el.addEventListener('click', () => {
        const [provider = '', model = ''] = (el.dataset.val || '').split('|');
        const row = this.modelRows.find(r => r.provider === provider && r.model === model);
        if (row?.agent) {
          void this.pickOrderModel(provider, model);
          this.externalDetail = `${provider}|${model}`;
          const externalGroup = this.container.querySelector<HTMLDetailsElement>('#model-external-group');
          if (externalGroup) externalGroup.open = true;
          this.renderExternalDetail();
        } else void this.pickOrderModel(provider, model);
      });
    });
    // La lista del enjambre comparte la búsqueda: un mismo «q» estrecha ambas.
    this.renderSwarmList();
  }

  /**
   * T2d-D6: grupo final de la lista con los agentes que «Solo gratis» deja
   * fuera. No son `.model-item`: ni se pueden pulsar ni entran en el recorrido
   * del teclado; solo dicen por qué no están.
   */
  private freeBlockedGroup(q: string): string {
    const list = (this.freeBlockedRows ?? []).filter(r => !q ||
      r.model.toLowerCase().includes(q) || r.provider.toLowerCase().includes(q) || (r.label ?? '').toLowerCase().includes(q));
    if (!list.length) return '';
    return `<details class="model-group" data-group="free-blocked" open>
             <summary tabindex="-1" aria-expanded="true">No entran en Solo gratis <span class="model-group__count">${list.length}</span></summary>
             <div>${list.map(r => `<div class="model-blocked" aria-disabled="true" data-blocked="${escapeAttribute(`${r.provider}|${r.model}`)}"><span class="model-blocked__name">${esc(r.label ?? r.model)}</span></div>`).join('')}</div>
           </details>`;
  }

  private syncGroupButton(): void {
    const button = this.container.querySelector<HTMLButtonElement>('#model-groups-toggle');
    const groups = [...this.container.querySelectorAll<HTMLDetailsElement>('#model-list .model-group')];
    if (!button) return;
    button.disabled = !!this.modelQuery.trim() || groups.length === 0;
    button.textContent = groups.length && groups.every(d => d.open) ? 'Colapsar todo' : 'Expandir todo';
  }

  private modelPickerKeydown(event: KeyboardEvent): void {
    if (!['ArrowDown', 'ArrowUp', 'ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) return;
    const target = event.target as HTMLElement;
    if (!target.matches('#model-search, #model-list summary, #model-list .model-item')) return;
    const controls = [...this.container.querySelectorAll<HTMLElement>('#model-list summary, #model-list .model-item')]
      .filter(el => el.tagName === 'SUMMARY' || !el.closest('details') || el.closest<HTMLDetailsElement>('details')?.open);
    const group = target.closest<HTMLDetailsElement>('.model-group');
    if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
      if (!group) return;
      group.open = event.key === 'ArrowRight';
      group.querySelector<HTMLElement>('summary')?.focus();
      this.syncModelListFocus();
    } else {
      const index = controls.indexOf(target);
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? controls.length - 1
        : event.key === 'ArrowDown' ? Math.min(index + 1, controls.length - 1) : Math.max(index - 1, 0);
      controls[next]?.focus();
      controls[next]?.scrollIntoView({ block: 'nearest' });
    }
    event.preventDefault();
  }

  /** Un punto de Tab; flechas recorren encabezados y opciones visibles. */
  private syncModelListFocus(preferred?: HTMLElement): void {
    const host = this.container.querySelector<HTMLElement>('#model-list');
    if (!host) return;
    const controls = [...host.querySelectorAll<HTMLElement>('summary, .model-item')];
    const visible = controls.filter(el => el.tagName === 'SUMMARY' || !el.closest('details') || el.closest<HTMLDetailsElement>('details')?.open);
    const active = host.ownerDocument?.activeElement as HTMLElement | null;
    const collapsed = active && controls.includes(active) && !visible.includes(active)
      ? active.closest('details')?.querySelector<HTMLElement>('summary') : null;
    const current = preferred ?? collapsed ?? active;
    const entry = current && visible.includes(current) ? current
      : visible.find(el => el.tabIndex === 0) ?? visible[0];
    controls.forEach(el => { el.tabIndex = el === entry ? 0 : -1; });
    if (collapsed) collapsed.focus();
  }

  /** Fija el modelo de la orden desde la lista; equivale a cambiar #sel-model. */
  private async pickOrderModel(provider: string, model: string): Promise<void> {
    if (!this.core) return;
    try {
      await this.applyOrderModelChoice(provider, model);
      if (provider && model) this.pushRecentModel(`${provider}|${model}`);
      await this.refreshModelPickers();
    } catch (error) {
      notice(`No se pudo fijar el modelo: ${String(error)}`, 'error');
    }
  }

  /**
 * (9-nov): una IDE normal recuerda el modelo elegido. El motor lo
   * guarda solo en memoria, así que al abrir la cabina se reaplica el último
   * elegido (una sola vez y solo si el motor sigue en Automático). Si el motor
   * ya no lo admite (proveedor quitado, clave borrada), se olvida y queda en
   * Automático, que es lo que habría sin recuerdo.
   */
  private orderModelRestored = false;
  private orderModelRestoring: Promise<void> | null = null;
  /**
 * (10-nov): idempotente y compartido. Un envío nada más abrir
   * salía con «Automático» (orden 937) porque el recuerdo se aplicaba después;
   * `submit` espera a esta misma promesa antes de comprobar la configuración.
   */
  private restoreSavedOrderModel(): Promise<void> {
    if (!this.orderModelRestoring) this.orderModelRestoring = this.restoreSavedOrderModelOnce();
    return this.orderModelRestoring;
  }
  private async restoreSavedOrderModelOnce(): Promise<void> {
    if (this.orderModelRestored || !this.core) return;
    this.orderModelRestored = true;
    const saved = readOrderModel();
    if (!saved) return;
    const [provider = '', model = ''] = saved.split('|');
    try {
      const none = { provider: '', model: '' };
      const [plan, exec] = await Promise.all([
        this.core.getPlanModel().catch(() => none),
        typeof this.core.getExecModel === 'function' ? this.core.getExecModel().catch(() => none) : Promise.resolve(none),
      ]);
      if (plan?.provider || exec?.provider) return; // el motor ya tiene un modelo fijado
      await this.applyOrderModelChoice(provider, model);
    } catch {
      saveOrderModel('');
    }
  }

  /**
 * enruta la elección del selector al rol que le corresponde.
   * Una CLI sin protocolo de plan/veredicto va al EJECUTOR y deja intacto el
   * planificador (el motor la bloquearía con text_role_unsupported como
   * planificadora, order_preflight.zig:20). r2: si quedó un pin viejo de
   * planificador con una CLI incompatible (sesiones anteriores al arreglo),
   * elegir un ejecutor CLI lo limpia — vuelve a automático — para no dejar la
   * orden bloqueada por un pin que el motor ya no admite.
   */
  private async applyOrderModelChoice(provider: string, model: string): Promise<void> {
    if (!this.core) return;
    saveOrderModel(provider && model ? `${provider}|${model}` : '');
    if (MissionControlPanel.executorOnlyCli(provider)) {
      await this.core.setExecModel(provider, model);
      const [planProvider = ''] = this.pinnedRoles.plan.split('|');
      if (MissionControlPanel.executorOnlyCli(planProvider)) await this.core.setPlanModel('', '');
      this.mainCliChoice = `${provider}|${model}`;
      return;
    }
    await this.core.setPlanModel(provider, model);
    this.mainCliChoice = '';
    const execProvider = this.pinnedRoles.exec.split('|')[0];
    // T2d-D2 (12-nov): en Directo corre un solo modelo y el motor da
    // prioridad al ejecutor (c_api: exec ?? plan). Un ejecutor que quedó de
    // una elección anterior (OpenCode) seguía corriendo aunque el usuario
    // eligiera Codex después; tras recargar la cabina ni siquiera se sabía
    // que venía del selector. Aquí la última elección manda.
    // Se limpia sin mirar `pinnedRoles`, que tras una recarga puede ir por
    // detrás del motor.
    if (this.directMode) {
      await this.core.setExecModel('', '');
    } else if (MissionControlPanel.executorOnlyCli(execProvider) && !this.explicitRoleRows?.has('exec')) {
      await this.core.setExecModel('', '');
    }
  }

  /**
 * mismo criterio que core/src/order_preflight.zig:20 — de las
   * CLI `agent:<cli>`, solo `agent:codex` ofrece el protocolo de plan/veredicto.
   * El resto solo puede ocupar el rol de ejecutor.
   */
  private static executorOnlyCli(provider: string): boolean {
    return provider.startsWith('agent:') && provider !== 'agent:codex';
  }

  /**
   * r2/r3: motivo visible (mismo sentido que order_preflight.zig:23) para los
   * roles que una CLI sin protocolo no puede ocupar. Un solo texto para que
   * planificador y auditor expliquen lo mismo.
   */
  private static readonly cliRoleBlockedTitle = 'Este CLI no ofrece el protocolo de plan/veredicto; elige Codex o un modelo de nube para este rol';

  /** Resumen de pins dentro del panel (línea de estado, no interactiva). */
  public showConfiguration(check: { budget?: {authorized:number;spent:number;remaining:number}; paid_roles?:boolean[]; allowed: boolean; issues: Array<{role:string;provider:string;model:string;reason:string;action:string;cause?:string;severity?:'block'|'warn';authorized?:number|null;spent?:number|null;remaining?:number|null}>; message:string }): void {
    let host = this.container.querySelector<HTMLElement>('#order-configuration');
    if (!host) {
      host = document.createElement('div'); host.id = 'order-configuration'; host.setAttribute('role','status');
      const input = this.container.querySelector('#mission-composer-input');
      (input?.parentElement ?? this.container).appendChild(host);
    }
    const hasIssues = check.issues.length > 0;
    // La explicación de política (sin conflictos) NO es un aviso: en naranja y
    // siempre visible ensuciaba el compositor («Respaldo: se prueba el siguiente
    // candidato elegible distinto» en cada render, main.ts:749). El naranja se
    // reserva a conflictos reales; la política de respaldo solo se explica en
    // color secundario y cuando aporta — modelo fijo/determinista.
    const deterministic = /determinista|sin respaldo/i.test(check.message || '');
    const paid = check.paid_roles;
    const tasks = Math.max(1, this.plan?.tasks?.length ?? 0);
    const estimated = paid ? (this.plan?.tasks?.length ? 0 : Number(paid[0])) + tasks * (Number(paid[1]) + Number(paid[2])) : 0;
    const lowBudget = !!check.budget && estimated > check.budget.remaining;
    const budgetExhausted = check.issues.some(i => i.cause === 'paid_budget_exhausted');
    // P2 (corrección auditoría): con presupuesto bajo el bloque ya se muestra
    // aunque no haya conflictos; debe ir en color de aviso igual que un
    // conflicto, o el aviso de cupo (y su botón «Autorizar más llamadas») pasa
    // desapercibido. La política determinista, sin presupuesto bajo, sigue en
    // color secundario: es una explicación, no una alerta.
    // propietario (10-nov): los avisos ya no se escriben bajo el chat. Cada conflicto
    // es una alerta abajo a la derecha que se pliega en un punto «!»: ámbar si
    // no bloquea el envío, roja si lo bloquea (ver design/alerts.ts). Bajo el
    // compositor solo queda la nota secundaria de «sin respaldo».
    const raised = new Set<string>();
    const roleName = (role: string): string => ({ planificador: 'Planificador', ejecutor: 'Ejecutor', auditor: 'Auditor' } as Record<string, string>)[role] ?? role;
    const authorize = { label: 'Autorizar más llamadas', run: () => document.dispatchEvent(new CustomEvent('devagents:settings-section', { detail: 'governance' })) };
    const openModel = { label: 'Elegir otro modelo', run: () => this.container.querySelector<HTMLElement>('#btn-model-picker')?.click() };
    for (const i of check.issues) {
      const id = `preflight:${i.role}:${i.cause || 'issue'}`;
      raised.add(id);
      const exhausted = i.cause === 'paid_budget_exhausted';
      const warnOnly = i.severity === 'warn' || i.cause === 'provider_recent_failure';
      raiseAlert({
        id,
        level: warnOnly ? 'warn' : 'error',
        title: `${roleName(i.role)}: ${this.shortModel(`${i.provider}|${i.model}`)}`,
        body: [exhausted ? `Cupo agotado: ${i.spent} de ${i.authorized} llamadas de pago autorizadas usadas (${i.remaining} restantes).` : `${i.reason}.`,
          i.action ? `${i.action}.` : '',
          (i.cause === 'audit_unavailable_by_preferences' || i.cause === 'audit_unavailable') ? 'Puedes enviar la orden sin auditoría independiente; el aviso no bloquea el envío.' : ''].filter(Boolean).join('\n'),
        actions: exhausted ? [authorize] : [openModel],
      });
    }
    if (lowBudget && !budgetExhausted) {
      raised.add('preflight:budget-low');
      raiseAlert({
        id: 'preflight:budget-low',
        level: 'warn',
        title: `Pago: ${check.budget!.remaining} llamadas restantes`,
        body: `Se estiman al menos ${estimated} llamadas para los roles de pago fijados${this.plan?.tasks?.length ? ' del plan' : ''}. Automáticos y reintentos no incluidos. Autoriza más o cambia a gratis/suscripción.`,
        actions: [authorize],
      });
    }
    clearAlertsExcept('preflight:', raised);
    host.style.cssText = 'font-size:12px;white-space:pre-wrap;padding:6px;color:var(--fg-muted)';
    // «Sin respaldo» ya se ve como chip junto a Modos (renderModeChips); aquí
    // no se repite como línea fija bajo el compositor (QA del propietario).
    void deterministic;
    host.textContent = '';
    host.style.display = 'none';
    if (host.dataset) host.dataset.issues = String(check.issues.length);
  }

  private renderPinSummary(): void {
    const el = this.container.querySelector<HTMLElement>('#model-detail-pins');
    if (!el) return;
    const { plan, exec, audit } = this.pinnedRoles;
    el.textContent = [plan ? this.shortModel(plan) : 'Orden automática',
      exec ? `ejecuta ${this.shortModel(exec)}` : 'ejecuta igual',
      audit ? `audita ${this.shortModel(audit)}` : 'auditor automático'].join(' · ');
    const warning = this.container.querySelector<HTMLElement>('#model-audit-warning');
    if (!warning) return;
    // Pins express intent. Only the order's native routing event can classify
    // its effective executor/auditor; the composer has no assignment yet.
    // B1e: en Directo/DevAgents responde el modelo elegido, sin plan ni
    // revisión que decidir (las subtareas delegadas traen su propio auditor).
    warning.textContent = this.directMode ? '' : 'Revisión por decidir · pendiente de asignación del motor';
    warning.hidden = !warning.textContent;
  }

  private renderExternalDetail(): void {
    const host = this.container.querySelector<HTMLElement>('#external-model-detail');
    if (!host || !this.core) return;
    const group = this.container.querySelector<HTMLDetailsElement>('#model-external-group');
    const current = this.externalDetail || this.pinnedRoles.exec || this.pinnedRoles.audit;
    const row = this.modelRows.find(r => r.agent && `${r.provider}|${r.model}` === current);
    if (!row) {
      host.replaceChildren();
      if (group) {
        group.hidden = true;
        const summary = group.querySelector('summary');
        if (summary) summary.textContent = 'Agente externo';
      }
      return;
    }
    if (group) {
      group.hidden = false;
      const summary = group.querySelector('summary');
      if (summary) summary.textContent = `Agente externo · ${row.group ?? row.provider}`;
    }
    const signature = row.signature === 'trusted' ? 'firma verificada'
      : row.signature === 'unsigned' ? 'sin firma' : 'firma sin verificar';
    // r2: una CLI sin protocolo de plan/veredicto no puede fijarse
    // como planificadora — el preflight la bloquearía (order_preflight.zig:20-23).
    // r3: el rol de auditor tiene la misma regla del motor. Los botones se
    // deshabilitan y explican el motivo; Codex y los modelos de nube siguen
    // ofreciendo las acciones como antes.
    const cliRoleBlocked = MissionControlPanel.executorOnlyCli(row.provider);
    const cliRoleTitle = cliRoleBlocked ? MissionControlPanel.cliRoleBlockedTitle : '';
    host.innerHTML = `<div class="external-cli-summary">${esc(row.group ?? row.provider)} ${esc(row.version ?? 'versión desconocida')} · ${esc(row.billingFree ? 'gratis' : row.session === 'suscripcion' ? 'suscripción' : row.session ?? 'sesión desconocida')} · ${signature}</div>
      <div class="external-cli-note">${row.billingFree ? 'Modelo gratuito; no cobra por llamada.' : 'La suscripción consume cuota; no cobra por llamada.'}</div>
      <div class="model-role-actions"><button class="btn btn--sm" id="external-pin-plan" ${row.available && !cliRoleBlocked ? '' : 'disabled'} title="${escapeAttribute(cliRoleTitle)}">Usar como planificador</button><button class="btn btn--sm" id="external-pin-exec" ${row.available ? '' : 'disabled'}>Usar como ejecutor</button><button class="btn btn--sm" id="external-pin-audit" ${row.available && !cliRoleBlocked ? '' : 'disabled'} title="${escapeAttribute(cliRoleTitle)}">Usar como auditor</button></div>
      ${row.efforts?.length ? `<label class="model-detail__label" for="external-reasoning">Esfuerzo de razonamiento</label><select class="select" id="external-reasoning"><option value="">Por defecto</option>${row.efforts.map(e => `<option value="${escapeAttribute(e)}" ${e === row.effort ? 'selected' : ''}>${esc(e)}</option>`).join('')}</select>` : ''}
      <details class="external-cli-detail"><summary aria-expanded="false" aria-controls="external-cli-detail-body">Ver detalle</summary>
        <div id="external-cli-detail-body">
        <div class="external-cli-metadata">Modelo: ${esc(row.label ?? row.model)}<br>Binario: ${esc(row.exe ?? '')}<br>Versión: ${esc(row.version ?? '')}<br>${esc(row.reason ?? '')}<br>Authenticode: ${esc(row.signature ?? 'not_checked')}<br>SID AppContainer aceptados: ${esc(row.aclSignals?.join(', ') || 'ninguno')}<br>${row.aclWriters?.length ? `Apps que pueden modificar la instalación: ${esc(row.aclWriters.join(', '))}<br>` : ''}${row.enumeration === 'enumerated' ? 'Modelos enumerados sin llamada' : 'Modelos: no enumerables sin llamada'}</div>
        <label class="model-detail__label" for="external-path">Ruta del ejecutable (opcional)</label><input class="input" id="external-path" placeholder="Automática: versión más reciente" /><button class="btn btn--sm" id="external-path-save">Aplicar ruta</button>
        </div>
      </details>`;
    const detail = host.querySelector<HTMLDetailsElement>('.external-cli-detail');
    detail?.addEventListener('toggle', () => detail.querySelector('summary')?.setAttribute('aria-expanded', String(detail.open)));
    const core = this.core;
    const pin = (role: 'plan'|'exec'|'audit') => {
      void (role === 'plan' ? core.setPlanModel(row.provider,row.model) : role === 'exec' ? core.setExecModel(row.provider,row.model) : core.setAuditModel(row.provider,row.model))
        .then(() => this.refreshModelPickers()).catch(e => notice(String(e),'error'));
    };
    // r2/r3: sin listener para la CLI incompatible — un botón deshabilitado no
    // debe fijar nada ni siquiera ante un click sintético.
    if (!cliRoleBlocked) host.querySelector('#external-pin-plan')?.addEventListener('click',() => pin('plan'));
    host.querySelector('#external-pin-exec')?.addEventListener('click',() => pin('exec'));
    if (!cliRoleBlocked) host.querySelector('#external-pin-audit')?.addEventListener('click',() => pin('audit'));
    host.querySelector<HTMLSelectElement>('#external-reasoning')?.addEventListener('change', e => {
      const selected = (e.target as HTMLSelectElement).value;
      void core.setExternalModelOptions(row.provider,row.model,selected).then(() => { row.effort = selected; })
        .catch(e => { this.renderExternalDetail(); notice(String(e),'error'); });
    });
    void core.getExternalPaths().then(paths => {
      const input = host.querySelector<HTMLInputElement>('#external-path');
      if (input) input.value = paths[row.provider.slice(6)] ?? '';
    }).catch(e => notice(String(e),'error'));
    host.querySelector('#external-path-save')?.addEventListener('click',() => {
      const path = host.querySelector<HTMLInputElement>('#external-path')?.value.trim() ?? '';
      void core.getExternalPaths().then(paths => core.setExternalPaths({...paths,[row.provider.slice(6)]:path}))
        .then(() => core.refreshExternalAgents()).then(() => this.refreshModelPickers()).catch(e => notice(String(e),'error'));
    });
  }

  /** ENJAMBRE: pinta la lista checkbox del catálogo; comparte la búsqueda del picker. */
  private renderSwarmList(): void {
    const host = this.container.querySelector<HTMLElement>('#swarm-list');
    if (!host) return;
    const q = this.modelQuery.trim().toLowerCase();
    const rows = this.modelRows.filter(r => r.automaticAllowed !== false).filter(
      (r) =>
        !q ||
        r.model.toLowerCase().includes(q) ||
        r.provider.toLowerCase().includes(q) ||
        (r.label ?? '').toLowerCase().includes(q)
    );
    const item = (v: string, name: string, prov: string, tags = '', available = true) => {
      const picked = this.swarmSelection.includes(v);
      return `<label class="swarm-item ${picked ? 'is-picked' : ''}" title="${esc(prov)} / ${escapeAttribute(name)}">
        <input type="checkbox" value="${escapeAttribute(v)}" ${picked ? 'checked' : ''} ${this.swarmAuto || this.swarmEnabled === false || !available ? 'disabled' : ''} data-available="${available}" />
        <span class="swarm-item__name">${esc(name)}</span>${tags}
        <span class="swarm-item__prov">${esc(prov)}</span>
      </label>`;
    };
    // Los elegidos van primero — como «Favoritos»/«Recientes» en la lista del
    // picker — para que la selección se vea sin tener que buscarla entre
    // cientos de filas.
    const tag = (r: (typeof rows)[number]) =>
      (r.fav ? '<span class="model-tag model-tag--fav">&#9733;</span>' : '') +
      (r.agent
        ? `<span class="model-tag">${esc(r.billingFree ? 'Gratis' : r.session === 'suscripcion' ? 'Suscripción' : r.session === 'api_key' ? 'API bloqueada' : 'Sesión no confirmada')}</span>`
        : r.free
          ? '<span class="model-tag model-tag--free">Gratis</span>'
          : '<span class="model-tag">Pago</span>') +
      (r.local ? '<span class="model-tag">Local</span>' : '') +
      (r.available || r.agent ? '' : '<span class="model-tag model-tag--off">caído</span>');
    const pickedRows = rows.filter((r) => this.swarmSelection.includes(`${r.provider}|${r.model}`));
    const restRows = rows.filter((r) => !this.swarmSelection.includes(`${r.provider}|${r.model}`));
    host.innerHTML =
      this.swarmExtras
        .map((v) =>
          item(v, v.split('|')[1] || v, v.split('|')[0] || '', '<span class="model-tag model-tag--off">fuera de catálogo</span>')
        )
        .join('') +
      this.swarmBlocked
        .map((v) =>
          item(v, v.split('|')[1] || v, v.split('|')[0] || '', '<span class="model-tag model-tag--off">fuera del reparto por gobernanza o preferencias</span>', false)
        )
        .join('') +
      (this.swarmPinnedHidden ?? []).map(r => item(r.value, r.label, r.value.split('|')[0] || '', '<span class="model-tag">oculto en selectores · miembro guardado</span>', r.available)).join('') +
      pickedRows.map((r) => item(`${r.provider}|${r.model}`, r.label ?? r.model, r.provider, tag(r), r.available)).join('') +
      restRows.map((r) => item(`${r.provider}|${r.model}`, r.label ?? r.model, r.provider, tag(r), r.available)).join('') ||
      '<span class="subtle" style="padding:6px 8px;display:block">Sin modelos que coincidan con la búsqueda.</span>';
  }

  /** ENJAMBRE: refleja swarmAuto/selection en el checkbox, la lista y la pista. */
  private syncSwarmControls(): void {
    const chk = this.container.querySelector<HTMLInputElement>('#chk-swarm-auto');
    const list = this.container.querySelector<HTMLElement>('#swarm-list');
    const hint = this.container.querySelector<HTMLElement>('#swarm-hint');
    if (chk) { chk.checked = this.swarmAuto; chk.disabled = this.swarmEnabled === false; }
    const enabled = this.container.querySelector<HTMLInputElement>('#chk-swarm-enabled');
    if (enabled) enabled.checked = this.swarmEnabled !== false;
    // La lista queda siempre visible, como las de los otros roles: con
    // «Automático» muestra el catálogo atenuado y sus casillas inertes — se
    // ve de qué pool tira el router sin que el control parezca escondido.
    if (list) {
      list.classList.toggle('is-disabled', this.swarmAuto || this.swarmEnabled === false);
      list.querySelectorAll<HTMLInputElement>('input[type="checkbox"]').forEach((c) => {
        c.disabled = this.swarmAuto || this.swarmEnabled === false || c.dataset.available === 'false';
      });
    }
    if (hint) {
      // MODELO-LOCAL: los miembros que corren en la máquina (Ollama) se
      // ejecutan DE UNO EN UNO por defecto aunque el enjambre los reparta —
      // el motor protege al equipo de varias inferencias locales a la vez.
      const hasLocal = this.swarmSelection.some(
        (v) => this.modelRows.find((r) => `${r.provider}|${r.model}` === v)?.local
      );
      const localNote = hasLocal ? ' Los modelos locales corren en secuencia (sin paralelismo).' : '';
      hint.textContent = this.swarmEnabled === false ? 'Enjambre desactivado; se conservan sus miembros.' : this.swarmAuto
        ? 'El router elige el modelo de cada tarea por gobernanza y salud.'
        : this.swarmSelection.length === 1
          ? 'Un solo miembro: todas las tareas productoras usan ese modelo.'
          : `${this.swarmSelection.length} modelos se reparten las tareas en paralelo (máx. 8).` + localNote;
    }
    this.updateModelChip();
    this.syncModesPanel();
  }

  /**
   * ENJAMBRE: aplica la selección actual del multi-select al motor. Vacío =
   * Automático. El tope de 8 lo cumple la UI antes de llamar (el motor también
   * lo valida; rechazar aquí ahorra la vuelta).
   */
  private async applySwarm(members: string[]): Promise<void> {
    if (!this.core) return;
    const list = this.container.querySelector<HTMLElement>('#swarm-list');
    const prev: string[] = JSON.parse(list?.dataset.committed || '[]');
    if (members.length > 8) {
      notice('El enjambre admite como máximo 8 modelos.', 'error');
      this.restoreSwarmSelection(prev);
      return;
    }
    try {
      await this.core.setSwarmModels(
        members.map((v) => {
          const [provider = '', model = ''] = v.split('|');
          return { provider, model };
        })
      );
      this.swarmSelection = members;
      this.swarmAuto = members.length === 0;
      if (list) list.dataset.committed = JSON.stringify(members);
      // Re-render tras confirmar: un refresh en vuelo puede haber repintado
      // la lista desde el estado anterior mientras el motor respondía.
      this.renderSwarmList();
      // Aviso honesto de gobernanza: un miembro de pago con "Solo gratis"
      // queda fijado pero el motor lo excluye del reparto (y si ninguno pasa,
      // la orden cae en "enjambre agotado"). Decirlo al fijarlo evita la
      // sorpresa posterior; fuera de catálogo cuenta como de pago, igual que
      // asume el motor.
      const gov = this.container.querySelector<HTMLSelectElement>('#sel-gov-mode')?.value;
      // E5.08: un miembro agent:* corre sobre la suscripción del usuario —
      // el motor lo trata como gratuito (sin coste marginal de API), así que
      // no va ni al aviso de "no entra en Solo gratis" ni al de presupuesto.
      if (gov === 'free' && members.length) {
        const paid = members.filter((v) => {
          const row = this.modelRows.find((r) => `${r.provider}|${r.model}` === v);
          return row ? !row.free && !row.agent : true;
        });
        if (paid.length) {
          notice(
            `Con "Solo gratis", ${paid.length === 1 ? 'este miembro no entra' : `estos ${paid.length} miembros no entran`} en el reparto (de pago o sin catalogar como gratis): ${paid.map((v) => this.shortModel(v)).join(', ')}.`,
            'info'
          );
        }
      } else if (members.length && this.orderId > 0) {
        // E1.17/F4: con gobernanza paid/híbrida un miembro de pago SÍ entra en
        // el reparto y consume presupuesto — el toast de coste lo dice a
        // tiempo, a mitad de conversación que es cuando duele.
        const paid = members.filter((v) => {
          const row = this.modelRows.find((r) => `${r.provider}|${r.model}` === v);
          return row ? !row.free && !row.agent : true;
        });
        if (paid.length) {
          notice(
            `${paid.length === 1 ? 'Este miembro es' : `Estos ${paid.length} miembros son`} de pago o no catalogados como gratis: consumen presupuesto autorizado en esta conversación: ${paid.map((v) => this.shortModel(v)).join(', ')}.`,
            'info'
          );
        }
      }
      this.updateModelChip();
      this.renderPinSummary();
      this.syncSwarmControls();
    } catch (error) {
      this.restoreSwarmSelection(prev);
      notice(`No se pudo fijar el enjambre: ${String(error)}`, 'error');
    }
  }

  /** ENJAMBRE: devuelve la lista al último estado confirmado por el motor. */
  private restoreSwarmSelection(members: string[]): void {
    this.swarmSelection = members;
    this.swarmAuto = members.length === 0;
    this.renderSwarmList();
    this.syncSwarmControls();
  }

  /** Sin respaldo y enjambre son decisiones independientes de los pines. */
  private syncDeterministicAvailability(_hasPinnedModel: boolean): void {
    const chk = this.container.querySelector<HTMLInputElement>('#chk-deterministic');
    const lbl = this.container.querySelector<HTMLElement>('#lbl-deterministic');
    if (!chk || !lbl) return;
    chk.disabled = false;
    lbl.style.opacity = '1';
    lbl.style.cursor = 'pointer';
    lbl.title = 'Sin respaldo: cada selección usa su primer candidato; si falla, la orden falla.';
  }

  // --- Render ---------------------------------------------------------------

  private render(): void {
    this.container.innerHTML = `
      <div class="col grow" style="height:100%;background:var(--bg-main)">

        <div class="banner banner--warning" id="mission-banner" style="display:none">
          <span class="row" style="gap:8px">${icons.alert(14)}<span id="mission-banner-text"></span></span>
          <button class="btn btn--sm btn--primary" id="btn-config-key" title="Abre la configuración para registrar o revisar la clave de este proveedor">Configurar</button>
        </div>

        <div class="grow" style="position:relative;min-height:0;display:flex;flex-direction:column">
          <div class="orbit-layer orbit-layer--vivo" id="mission-orbit" aria-hidden="true">${orbitBackdrop()}</div>
          <div class="grow scroll-y" id="mission-body" style="display:flex"></div>
          <div id="mission-minimap" style="display:none" title="Minimapa del transcript: cada marca es un bloque; clic salta a él"></div>
        </div>

        <div style="padding:12px 16px 16px">
          <div class="card" id="mission-composer" style="padding:10px 12px;gap:8px;display:flex;flex-direction:column;position:relative">
            <div class="mention-popup" id="mention-popup" style="display:none"></div>
            <!-- MODOS: ventana con la forma de trabajar, permisos, coste y la
                 configuración avanzada. Los selects reales viven aquí dentro
                 (ocultos) y siguen siendo la única fuente de verdad. -->
            <div class="modes-pop" id="modes-picker" role="group" aria-labelledby="modes-picker-title" style="display:none">
              <div class="sr-only" id="modes-picker-title">Modos de la orden</div>
              <div id="modes-picker-body">
                <div class="modes-section">
                  <div class="modes-section__title">Forma de trabajar</div>
                  <div class="modes-ways" role="group" aria-label="Forma de trabajar">
                    <button type="button" class="modes-way" data-way="directo" aria-pressed="false"
                            title="Un solo modelo, como cualquier CLI o IDE de IA">
                      <b>Directo</b>
                      <small>Un modelo conversa, lee, edita y ejecuta en tu proyecto, sin plan, colmena ni auditoría. Como una CLI.</small>
                    </button>
                    <button type="button" class="modes-way" data-way="devagents" aria-pressed="false"
                            title="Directo que reparte en paralelo: cada subtarea en su worktree, auditada por otro modelo">
                      <b class="row" style="gap:6px;align-items:center">${icons.delegate(14)}DevAgents</b>
                      <small>Conversas con un modelo y él delega subtareas en paralelo en otros modelos, cada una en su worktree.</small>
                    </button>
                    <button type="button" class="modes-way" data-way="orquestado" aria-pressed="false">
                      <b>Orquestado</b>
                      <small>Planifica, reparte tareas por rol y audita con otro fabricante.</small>
                    </button>
                    <button type="button" class="modes-way is-active" data-way="colmena" aria-pressed="true">
                      <b>Colmena</b>
                      <small>Orquestado, y varios modelos ejecutan en paralelo (máx. 8).</small>
                    </button>
                  </div>
                </div>
                <div class="modes-section">
                  <div class="modes-section__title">Antes de ejecutar</div>
                  <label for="wait-plan-approval" class="modes-opt" title="Investiga y propone el plan. Solo ejecuta cuando pulses Aprobar y ejecutar.">
                    <span class="modes-opt__tx"><b>Esperar mi aprobación del plan</b><small>Investiga y propone; solo ejecuta cuando pulses «Aprobar y ejecutar». También con <code>/plan</code>.</small></span>
                    <input type="checkbox" class="sw" id="wait-plan-approval" ${this.planOnly ? 'checked' : ''} />
                  </label>
                  <!-- Sin respaldo y enjambre se gobiernan por separado. -->
                  <label id="lbl-deterministic" class="modes-opt" for="chk-deterministic"
                         title="Sin respaldo: si el primer candidato falla, la orden falla">
                    <span class="modes-opt__tx"><b>Sin respaldo</b><small>Si el modelo falla, la orden falla nombrándolo en vez de probar otro. Activo, se ve como chip junto a «Modos».</small></span>
                    <input type="checkbox" class="sw" id="chk-deterministic" />
                  </label>
                </div>
                <div class="modes-section">
                  <div class="modes-section__title">Permisos</div>
                  <div class="model-detail__hint">Qué puede hacer sin pedirte permiso. «Auto» y «Omitir permisos» se confirman una vez en una ventana de DevAgents y quedan recordados en este equipo.</div>
                  <select class="select" id="sel-perm-mode" hidden
                          title="Cómo trabaja el agente y qué puede hacer sin pedirte permiso">
                    <option value="normal">Manual</option>
                    <option value="accept_edits">Aceptar ediciones</option>
                    <option value="plan">Plan</option>
                    <option value="autonomous">Auto</option>
                    <option value="bypass">Omitir permisos</option>
                  </select>
                  ${this.segmentedHtml('sel-perm-mode', [
                    ['normal', 'Manual'],
                    ['accept_edits', 'Aceptar ediciones'],
                    ['plan', 'Plan'],
                    ['autonomous', 'Auto', true],
                    ['bypass', 'Omitir permisos', true],
                  ])}
                </div>
                <div class="modes-section">
                  <div class="modes-section__title">Coste</div>
                  <select class="select" id="sel-gov-mode" hidden
                          title="Gobernanza de coste: qué modelos puede elegir el router">
                    <option value="hybrid">Híbrido</option>
                    <option value="free">Solo gratis</option>
                    <option value="paid">Prioriza pago</option>
                    <option value="local">Solo local</option>
                  </select>
                  ${this.segmentedHtml('sel-gov-mode', [
                    ['hybrid', 'Híbrido'],
                    ['free', 'Solo gratis'],
                    ['paid', 'Prioriza pago'],
                    ['local', 'Solo local'],
                  ])}
                  <div class="model-detail__hint" id="modes-paid-line"><span id="modes-paid-text"></span> · <a href="#" class="modes-link" id="modes-paid-authorize">Autorizar más</a></div>
                </div>
                <details class="modes-advanced" id="modes-advanced">
                  <summary aria-expanded="false" aria-controls="modes-advanced-body">Configuración avanzada</summary>
                  <div id="modes-advanced-body">
                    <div class="modes-section">
                      <label class="modes-graph"><input type="checkbox" id="chk-order-graph" ${graphEnabledNow() ? 'checked' : ''} />
                        <span class="modes-opt__tx"><b>Ver la orden como grafo</b><small>Contexto, plan, tareas en paralelo, auditoría y entrega, cada una con su estado. Apagado, la orden se resume en una tira de puntos.</small></span></label>
                    </div>
                    <div class="modes-section">
                      <div class="modes-opt__tx"><b>Mejor de N</b><small>N modelos de proveedores distintos hacen la orden en paralelo y tú eliges la ganadora. Multiplica el gasto por N.</small></div>
                      <!-- E5.18: Best-of-N — la orden la ejecutan N candidatas de
                           proveedores distintos, cada una en su worktree, y el
                           usuario elige la ganadora en la tarjeta comparativa. -->
                      <select class="select" id="sel-best-of-n" hidden
                              title="Best-of-N: N miembros del enjambre (proveedores distintos) ejecutan la orden en worktrees separados y tú eliges la ganadora. Multiplica el gasto por N.">
                        <option value="0">Desactivado</option>
                        <option value="2">Mejor de 2</option>
                        <option value="3">Mejor de 3</option>
                        <option value="4">Mejor de 4</option>
                      </select>
                      ${this.segmentedHtml('sel-best-of-n', [
                        ['0', 'Desactivado'],
                        ['2', 'Mejor de 2'],
                        ['3', 'Mejor de 3'],
                        ['4', 'Mejor de 4'],
                      ])}
                      <input class="input" type="text" id="inp-bon-members" spellcheck="false"
                             placeholder='Miembros JSON: [{"provider":"A","model":"m"}] (vacío = enjambre)'
                             title="Best-of-N: lista explícita de miembros [{provider,model}], cada uno de un proveedor distinto. Vacío = se toman N del enjambre configurado."
                             style="height:26px;width:100%;display:none" />
                    </div>
                    <!-- D2(a): replanificación autónoma. Con 1 la orden ejecuta el
                         plan aprobado una vez (estable). Con >=2 el motor observa
                         el resultado y puede re-planificar el siguiente paso bajo
                         la misma orden — cada iteración gasta modelo del mismo
                         presupuesto y se asienta como evento agent_iteration. -->
                    <div class="modes-opt">
                      <label class="modes-opt__tx" for="num-agentic"><b>Pasos del agente</b><small>1 = sin replanificar. Cada paso extra observa, replanifica y gasta modelo.</small></label>
                      <span class="modes-stepper">
                        <button type="button" data-step="-1" aria-label="Un paso menos" aria-controls="num-agentic">−</button>
                        <input type="number" id="num-agentic" min="1" max="12" step="1" value="1"
                               title="Cuántas veces puede el motor observar y re-planificar tras ejecutar. 1 = una sola pasada (sin replanificación)" />
                        <button type="button" data-step="1" aria-label="Un paso más" aria-controls="num-agentic">+</button>
                      </span>
                    </div>
                    <div class="modes-opt">
                      <!-- Ya SÍ llega al proveedor: el adaptador OpenAI emite
                           reasoning_effort en el cuerpo de la petición. -->
                      <label class="modes-opt__tx" for="sel-effort"><b>Esfuerzo de razonamiento</b></label>
                      <select class="select" id="sel-effort" hidden
                              title="Cuánto debe razonar el modelo antes de responder">
                        <option value="">Del proveedor</option>
                        <option value="low">Bajo</option>
                        <option value="medium">Medio</option>
                        <option value="high">Alto</option>
                      </select>
                      ${this.segmentedHtml('sel-effort', [
                        ['', 'Del proveedor'],
                        ['low', 'Bajo'],
                        ['medium', 'Medio'],
                        ['high', 'Alto'],
                      ])}
                    </div>
                    <!-- Maqueta: «Ver la orden como grafo». El grafo
                         aún no existe: el interruptor se ve, deshabilitado y con su motivo. -->
                    <label class="modes-opt is-off" title="Próximamente">
                      <span class="modes-opt__tx"><b>Ver la orden como grafo</b><small>Apagado por defecto. Pinta cada tarea como nodo con su rol y su modelo. Próximamente.</small></span>
                      <input type="checkbox" class="sw" id="chk-order-graph" disabled aria-disabled="true" />
                    </label>
                  </div>
                </details>
                <div class="modes-shortcuts">Escribe <code>/</code> al principio para ver los comandos (<code>/plan</code>, <code>/model</code>, <code>/init</code>…) · <code>@archivo</code> para citar archivos</div>
              </div>
            </div>
            <!-- PICKER-MODELO: panel plegable estilo Devin. Izquierda: lista
                 buscable agrupada (Favoritos / Recientes / por proveedor).
                 Derecha: roles y variantes — contiene los MISMOS controles de
                 siempre (#sel-model, #sel-model-exec, #sel-model-audit,
                 #sel-effort, #chk-deterministic) con sus IDs intactos. -->
            <div class="model-pop" id="model-picker" role="group" aria-labelledby="model-picker-title" style="display:none">
              <div class="model-pop__left">
                <div class="sr-only" id="model-picker-title">Selector de modelos</div>
                <div class="model-pop__search">
                  <input class="input" id="model-search" type="text" aria-label="Buscar modelos"
                         placeholder="Buscar modelos&#8230;"
                         style="width:100%;height:28px;font-size:12px" />
                </div>
                <div class="row" style="gap:6px;align-items:center"><button class="btn btn--sm" id="model-groups-toggle" type="button" aria-controls="model-list">Expandir todo</button><span class="model-detail__hint">↑↓ · ←→ pliega</span></div>
                <div class="model-pop__list" id="model-list" tabindex="-1"></div>
                <button class="btn" id="btn-external-refresh" type="button">Volver a detectar</button>
                <div class="subtle" id="external-detection-status" role="status"></div>
              </div>
              <div class="model-pop__right">
                <div class="modes-section__title">Modelo y roles</div>
                <div class="model-detail__hint">La orden la dirige el modelo elegido. Los roles lo heredan o se fijan aparte.</div>
                <!-- Fija el modelo de TODA la orden, no solo el de planificar:
                     plan_set_model llega a setForcedModel, y assignModel lo
                     devuelve como primario de cada tarea. -->
                <div class="model-role-grid">
                  <label class="model-role-grid__main" for="sel-model">Modelo de la orden</label>
                  <select class="select" id="sel-model"
                          title="Modelo de la orden; Automático devuelve el control al router">
                    <option value="">Automático</option>
                  </select>
                  <small>Planifica y dirige la orden.</small>
                </div>
                <div class="row" style="gap:6px">
                  <select class="select" id="sel-add-role" aria-label="Rol que añadir">
                    <option value="exec">Ejecutor</option><option value="audit">Auditor</option>
                    <option value="second_audit">Segundo auditor</option><option value="programmer">Programador</option>
                    <option value="sidekick">Sidekick</option>
                  </select>
                  <button class="btn btn--sm" id="btn-add-role" type="button">+ rol</button>
                  <span class="model-detail__hint model-add-role__limit">máx. 5</span>
                </div>
                <div id="model-role-rows"></div>
                <div class="model-detail__hint" id="model-audit-warning" role="status" hidden></div>
                <div class="model-detail__pins" id="model-detail-pins" role="status"></div>
                <details class="model-advanced" id="model-advanced" open>
                  <summary aria-expanded="true" aria-controls="model-advanced-body">Colmena (enjambre)</summary>
                  <div class="model-advanced__body" id="model-advanced-body">
                <!-- ENJAMBRE: conjunto cerrado de modelos para las tareas
                     productoras. "Automático" = el router decide por tarea,
                     como siempre. Con miembros elegidos el reparto es
                     determinista (N-ésima productora → miembro N%len) y los
                     respaldos también salen del conjunto: la orden nunca usa
                     un modelo que el usuario no eligió. -->
                <label class="modes-opt" for="chk-swarm-enabled">
                  <span class="modes-opt__tx"><b>Enjambre activo</b><small>El mismo interruptor que «Colmena» en Modos.</small></span>
                  <input type="checkbox" class="sw" id="chk-swarm-enabled" checked />
                </label>
                <label id="lbl-swarm-auto" class="modes-opt" for="chk-swarm-auto"
                       title="Con Automático el router elige el modelo de cada tarea por gobernanza y salud">
                  <span class="modes-opt__tx"><b>Reparto del enjambre</b><small>Automático (el router decide por tarea). Desmárcalo para elegir miembros.</small></span>
                  <input type="checkbox" class="sw" id="chk-swarm-auto" checked />
                </label>
                <div class="swarm-list" id="swarm-list"
                     title="Enjambre: modelos que se reparten las tareas productoras en paralelo. Máximo 8"></div>
                <div class="model-detail__hint" id="swarm-hint" style="margin-top:2px"></div>
                  </div>
                </details>
                <details class="model-group-ext" id="model-external-group" hidden>
                  <summary aria-expanded="false">Agente externo</summary>
                  <div class="model-group__body">
                    <div id="external-model-detail"></div>
                  </div>
                </details>
                <details class="model-group-vision" id="model-vision-group">
                  <summary aria-expanded="false">Visión</summary>
                  <div class="model-group__body">
                    <button class="btn btn--sm" id="btn-vision-probe" title="Sonda explícita del ejecutor seleccionado; el motor exige elegibilidad gratuita">Medir visión</button>
                    <div class="model-detail__hint" id="vision-probe-status" role="status" aria-live="polite">Visión sin medir. Elige un modelo y pulsa Medir visión.</div>
                  </div>
                </details>
              </div>
            </div>
            <textarea class="textarea" id="mission-composer-input" rows="2"
              placeholder="Describe tu orden. El agente la planifica, te enseña el plan y la ejecuta. (Enter para enviar, Shift+Enter para salto de línea)"
              style="background:transparent;border:none;padding:0"></textarea>
            <div class="row" id="composer-chips" style="flex-wrap:wrap;gap:6px"></div>
            <div class="row" style="justify-content:space-between;border-top:1px solid var(--border);padding-top:8px;gap:8px;flex-wrap:wrap">
              <div class="row" style="gap:6px;flex-wrap:wrap">
                <button class="icon-btn" id="btn-composer-attach" title="Adjuntar texto o imágenes PNG, JPEG o WebP (4 imágenes, 5 MB cada una)">${icons.paperclip(15)}</button>
                <button class="composer-pick" id="btn-modes-picker"
                        title="Forma de trabajar, permisos y coste de esta orden"
                        aria-expanded="false" aria-controls="modes-picker"
                        style="height:26px;width:auto;display:inline-flex;align-items:center;gap:6px;cursor:pointer">
                  ${icons.layers(13)} Modos ${icons.chevronDown(11)}
                </button>
                <!-- PICKER-MODELO (estilo Devin): un chip que abre el panel
                     plegable. TODOS los controles de modelo viven dentro del
                     panel con los mismos IDs y bindings de siempre — nada se
                     pierde, solo cambia dónde se presenta. -->
                <button class="composer-pick" id="btn-model-picker" title="Elige el modelo que planifica, ejecuta y audita esta orden" style="height:26px;width:auto;max-width:300px;display:inline-flex;align-items:center;gap:6px;cursor:pointer">
                  ${icons.model(13)}
                  <span id="model-chip-label" class="truncate">Automático · en colmena</span>
                  ${icons.chevronDown(11)}
                </button>
                <!-- QA-B 2c: cuenta de la CLI elegida (Codex o Claude Code), solo si
                     tiene cuentas dadas de alta en Configuración › Cuentas. -->
                <select class="composer-pick" id="composer-cli-account" hidden
                        title="Cuenta con la que empieza la CLI en esta orden; si agota su cuota, sigue con la siguiente"
                        aria-label="Cuenta de la CLI" style="height:26px;max-width:200px"></select>
                <div class="row" id="composer-mode-chips" style="gap:6px;flex-wrap:wrap"></div>
              </div>
              <div class="row" style="gap:8px">
                <!-- Porcentaje de contexto usado (misma fuente que la
                     tarjeta «Contexto» del panel derecho), con aviso y «Compactar ahora». -->
                <div class="ctx-meter" id="${ctxuse.ID_INDICADOR_CONTEXTO}" data-nivel="" hidden></div>
                <button class="btn btn--ghost btn--sm" id="btn-mission-cancel" title="Detiene la planificación o la ejecución en curso" style="display:none">Detener</button>
                <button class="btn btn--primary" id="btn-mission-send" title="Envía el mensaje o lanza la orden">${icons.send(14)} Enviar</button>
              </div>
            </div>
            <input type="file" id="composer-file-input" multiple style="display:none" />
          </div>
        </div>

      </div>`;

    this.bindShell();
    this.renderBody();
  }

  // --- Menciones @archivo ----------------------------------------------------
  //
  // Hasta ahora la única forma de darle contexto al agente era que lo buscara
  // solo, lo que gasta una vuelta entera de herramientas antes de empezar. Con
  // `@` se abre el árbol del proyecto sobre el compositor y la ruta elegida
  // viaja dentro del propio texto de la orden, que es lo que el planner lee.

  /** Cache del listado plano de archivos; se llena la primera vez que se usa @. */
  private mentionFiles: string[] | null = null;
  private mentionMatches: string[] = [];
  private mentionIndex = 0;
  /** Posición del `@` que abrió el autocompletado dentro del textarea. */
  private mentionAnchor = -1;

  /** Descripcion paralela a `mentionMatches` cuando el popup lista comandos. */
  private slashDescs: string[] = [];
  /** true cuando el popup lista comandos `/` en vez de archivos `@`. */
  private slashMode = false;

  /**
   * Comandos del compositor, al estilo de otras IDE.
   *
   * Reutilizan el MISMO popup que las menciones `@` a proposito: navegacion por
   * teclado, resaltado y aceptacion ya estaban resueltos ahi, y dos sistemas
   * paralelos sobre la misma caja es como se desincronizan.
   *
   * Cada uno enlaza con una accion que YA existia, escondida tras un boton.
   */
  private slashCommands(): SlashCommand[] {
    const click = (selector: string) => () => this.container.querySelector<HTMLElement>(selector)?.click();
    return [
      { nombre: '/nueva', desc: 'Conversacion nueva (rompe el hilo actual)', run: () => this.newConversation() },
      // 12-nov: los nombres que usan Claude Code y Codex, sobre acciones que ya existían.
      { nombre: '/clear', desc: 'Igual que /nueva: empieza una conversación limpia', run: () => this.newConversation() },
      { nombre: '/compactar', desc: 'Resumir el hilo y seguir con el resumen', run: () => void this.compactConversation() },
      { nombre: '/plan', desc: 'Modo Plan: planificar y parar, sin ejecutar', run: () => this.setPlanMode(!this.planOnly) },
      { nombre: '/model', desc: 'Elegir el modelo de la orden', run: click('#btn-model-picker') },
      { nombre: '/permissions', desc: 'Forma de trabajar, permisos y coste', run: click('#btn-modes-picker') },
      { nombre: '/init', desc: 'El agente estudia el proyecto y escribe AGENTS.md', run: () => this.initProjectGuide() },
      { nombre: '/undo', desc: 'Restaurar el último punto de control de esta conversación', run: () => void this.undoLastOrder() },
      { nombre: '/export', desc: 'Copiar la conversación al portapapeles en Markdown', run: () => void this.exportConversation() },
      ...this.slashExtras,
      // NO hay `/agente` ni `/dev`: `setMode` escribe `this.mode` y `getMode()`
      // no lo lee NADIE (item 20). Un comando que promete cambiar el modo y no
      // cambia nada es peor que no tenerlo. Vuelve cuando el modo haga algo.
    ];
  }

  /** Comandos que viven fuera del compositor (paleta, vistas); los aporta main.ts. */
  private slashExtras: SlashCommand[] = [];
  public setSlashExtras(extras: SlashCommand[]): void {
    this.slashExtras = extras;
  }

  /** /init: como en Claude Code y Codex, el agente escribe la guía del proyecto. */
  private initProjectGuide(): void {
    if (this.isBusy()) {
      notice('Hay una orden en marcha: espera a que termine para usar /init.', 'info');
      return;
    }
    const input = this.container.querySelector<HTMLTextAreaElement>('#mission-composer-input');
    const send = this.container.querySelector<HTMLButtonElement>('#btn-mission-send');
    if (!input || !send) return;
    input.value =
      'Estudia este proyecto (estructura, lenguajes, cómo se compila, cómo se prueba y convenciones de código) ' +
      'y escribe en la raíz un AGENTS.md breve con lo que necesita saber un agente para trabajar aquí: ' +
      'comandos exactos de compilación y pruebas, organización de carpetas y reglas de estilo. ' +
      'Si ya existe AGENTS.md, actualízalo sin perder lo que el usuario escribió.';
    input.dispatchEvent(new Event('input', { bubbles: true }));
    send.click();
  }

  /** /undo: el punto de control de la orden actual o, si no tiene, el del bloque anterior más reciente. */
  private async undoLastOrder(): Promise<void> {
    if (!this.canRestorePrior()) {
      notice('Hay una orden en marcha o esperando aprobación: no se puede restaurar ahora.', 'info');
      return;
    }
    // B1d: una vuelta de Directo que no escribió nada no es lo que se deshace.
    if (this.checkpoint && this.currentCheckpointOffered()) return this.revertToCheckpoint();
    const prior = [...this.priorOrders].reverse().find((p) => p.checkpoint);
    if (prior) return this.revertPrior(prior.orderId);
    notice('Esta conversación no tiene ningún punto de control que restaurar.', 'info');
  }

  /** /export: la conversación visible, en Markdown, al portapapeles. */
  private async exportConversation(): Promise<void> {
    const turns = Array.from(this.container.querySelectorAll<HTMLElement>('.chat-turn'))
      .map((turn) => turn.innerText.trim())
      .filter(Boolean);
    if (!turns.length) {
      notice('No hay nada que exportar en esta conversación.', 'info');
      return;
    }
    try {
      await navigator.clipboard.writeText(turns.join('\n\n---\n\n') + '\n');
      notice(`Conversación copiada al portapapeles (${turns.length} mensajes).`, 'ok');
    } catch (error) {
      notice('No se pudo copiar la conversación: ' + String(error), 'error');
    }
  }

  private mentionPopup(): HTMLElement | null {
    return this.container.querySelector<HTMLElement>('#mention-popup');
  }

  private closeMentions(): void {
    const popup = this.mentionPopup();
    if (popup) popup.style.display = 'none';
    this.mentionAnchor = -1;
    this.mentionMatches = [];
  }

  /**
   * Recorre el proyecto una vez y guarda las rutas relativas. Se limita en
   * profundidad y en número: un árbol enorme no debe congelar el compositor, y
   * para elegir un archivo a mano nadie baja de unos pocos miles.
   */
  private async loadMentionFiles(): Promise<string[]> {
    if (this.mentionFiles) return this.mentionFiles;
    if (!this.core) return [];
    const out: string[] = [];
    const walk = async (rel: string, depth: number): Promise<void> => {
      if (depth > 4 || out.length > 4000) return;
      let entries: Array<{ name: string; path: string; isDir: boolean }>;
      try {
        entries = (await this.core!.listDir(rel)).entries;
      } catch {
        return;
      }
      for (const e of entries) {
        if (out.length > 4000) return;
        // Carpetas que solo generan ruido en un selector de contexto.
        if (e.isDir && /^(\.git|node_modules|zig-out|\.zig-cache|dist)$/.test(e.name)) continue;
        if (e.isDir) await walk(e.path, depth + 1);
        else out.push(e.path);
      }
    };
    await walk('', 0);
    this.mentionFiles = out;
    return out;
  }

  private async updateMentions(input: HTMLTextAreaElement): Promise<void> {
    const caret = input.selectionStart ?? 0;
    const before = input.value.slice(0, caret);

    // Comandos `/`: solo al PRINCIPIO del compositor y sin espacios todavia.
    // Fuera de ahi una barra es una ruta o una fecha, no un comando.
    if (before.startsWith('/') && !/\s/.test(before)) {
      const q = before.toLowerCase();
      const hits = this.slashCommands().filter((c) => c.nombre.startsWith(q));
      this.slashMode = true;
      this.mentionMatches = hits.map((c) => c.nombre);
      this.slashDescs = hits.map((c) => c.desc);
      this.mentionAnchor = 0;
      this.mentionIndex = 0;
      this.renderMentions();
      return;
    }
    this.slashMode = false;
    this.slashDescs = [];
    const at = before.lastIndexOf('@');
    // Solo cuenta si la @ abre palabra y no hay espacios entre ella y el cursor.
    const query = at >= 0 ? before.slice(at + 1) : '';
    const opensWord = at === 0 || /\s/.test(before.charAt(at - 1));
    if (at < 0 || !opensWord || /\s/.test(query)) {
      this.closeMentions();
      return;
    }

    const files = await this.loadMentionFiles();
    const q = query.toLowerCase();
    this.mentionMatches = files
      .filter((f) => f.toLowerCase().includes(q))
      .slice(0, 8);
    this.mentionAnchor = at;
    this.mentionIndex = 0;
    this.renderMentions();
  }

  private renderMentions(): void {
    const popup = this.mentionPopup();
    if (!popup) return;
    if (!this.mentionMatches.length) {
      popup.style.display = 'none';
      return;
    }
    popup.style.display = '';
    popup.innerHTML = this.mentionMatches
      .map((f, i) => {
        const name = this.slashMode ? f : (f.split(/[\\/]/).pop() || f);
        const dir = this.slashMode
          ? (this.slashDescs[i] ?? '')
          : f.slice(0, f.length - name.length).replace(/[\\/]$/, '');
        return `<div class="mention-item ${i === this.mentionIndex ? 'is-active' : ''}" data-idx="${i}">
          <span class="mention-item__name">${esc(name)}</span>
          <span class="mention-item__dir">${esc(dir)}</span>
        </div>`;
      })
      .join('');
    popup.querySelectorAll<HTMLElement>('[data-idx]').forEach((el) => {
      el.addEventListener('mousedown', (ev) => {
        ev.preventDefault();
        this.acceptMention(Number(el.dataset.idx));
      });
    });
  }

  private acceptMention(idx: number): void {
    const input = this.container.querySelector<HTMLTextAreaElement>('#mission-composer-input');
    const file = this.mentionMatches[idx];
    if (!input || !file || this.mentionAnchor < 0) return;

    // Un comando no se INSERTA en el texto: se ejecuta y deja la caja limpia.
    if (this.slashMode) {
      const cmd = this.slashCommands().find((c) => c.nombre === file);
      this.closeMentions();
      input.value = '';
      input.style.height = 'auto';
      if (cmd) cmd.run();
      return;
    }
    const caret = input.selectionStart ?? 0;
    const head = input.value.slice(0, this.mentionAnchor);
    const tail = input.value.slice(caret);
    const inserted = `@${file} `;
    input.value = head + inserted + tail;
    const pos = head.length + inserted.length;
    input.setSelectionRange(pos, pos);
    input.focus();
    this.closeMentions();
  }

  /** Devuelve true si la tecla la consume el autocompletado. */
  private mentionsHandleKey(e: KeyboardEvent): boolean {
    if (this.mentionAnchor < 0 || !this.mentionMatches.length) return false;
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault();
      const delta = e.key === 'ArrowDown' ? 1 : -1;
      const n = this.mentionMatches.length;
      this.mentionIndex = (this.mentionIndex + delta + n) % n;
      this.renderMentions();
      return true;
    }
    if (e.key === 'Enter' || e.key === 'Tab') {
      e.preventDefault();
      this.acceptMention(this.mentionIndex);
      return true;
    }
    if (e.key === 'Escape') {
      e.preventDefault();
      this.closeMentions();
      return true;
    }
    return false;
  }

  private bindShell(): void {
    this.container.querySelector<HTMLInputElement>('#wait-plan-approval')?.addEventListener('change', (event) => {
      this.setPlanMode((event.target as HTMLInputElement).checked);
    });
    const input = this.container.querySelector<HTMLTextAreaElement>('#mission-composer-input');
    const send = this.container.querySelector('#btn-mission-send');
    this.container.querySelector('#btn-vision-probe')?.addEventListener('click', () => void this.probeSelectedVision());
    this.renderVisionProbeStatus();

    const trigger = () => {
      const busy = this.sendChecking || this.phase === 'planning' || this.phase === 'clarifying' || this.phase === 'running' || this.phase === 'best-of-n';
      if (busy) {
        // (10-nov): como en cualquier IDE con agente, lo que se
        // escribe mientras trabaja va a la COLA y sale solo al terminar. Antes
        // se avisaba y, al arrancar, dos envíos seguidos chocaban con la
        // comprobación del primero y uno se perdía. Con adjuntos o una
        // incidencia pendiente se mantiene el aviso (no se pueden encolar).
        const queued = input?.value.trim();
        if (queued && this.attachments.length === 0 && !this.pendingIssue) {
          this.sendQueue.push(queued);
          if (input) {
            input.value = '';
            input.style.height = 'auto';
          }
          this.renderSendQueue();
          return;
        }
        notice('Hay una orden en curso: el mensaje no se envió. Espera a que termine o cancélala.', 'info');
        return;
      }
      const text = input?.value.trim();
      if (!text) return;
      if (this.pendingIssue) {
        try { issueInstruction(text, this.pendingIssue.prompt); }
        catch (error) { notice(String(error), 'error'); return; }
      }
      if (this.attachmentReads > 0) {
        notice('Espera a que termine la validación de los adjuntos.', 'info');
        return;
      }
      // Enviar una orden retira el selector: dejarlo abierto taparía el plan.
      this.dismissModelPicker();
      this.dismissModesPicker();
      if (input) {
        input.value = '';
        input.style.height = 'auto';
      }
      // Solo el contexto textual se cita. Los bytes de imagen van por el
      // contrato del puente y el motor vuelve a validarlos.
      const pendingAttachments = this.attachments.slice();
      const extra = this.attachments
        .map((a) => 'content' in a
          ? `\n\n--- Archivo adjunto: ${a.name} ---\n${a.content}`
          : a.elementContext ? `\n\n${a.elementContext}` : '')
        .join('');
      this.attachError = '';
      this.renderChips();
      // 8-nov: el compositor se vacía antes de saber si la orden arranca; si
      // submit dice que no arrancó, el texto vuelve al compositor.
      void this.submit(text + extra, text, pendingAttachments).then((started) => {
        if (started === false && input && !input.value.trim()) {
          input.value = text;
          input.dispatchEvent(new Event('input', { bubbles: true }));
        }
      });
    };

    send?.addEventListener('click', trigger);
    // «Compactar ahora» del indicador: MISMA acción que el aviso del hilo y
    // /compactar (compactConversation); el puente no tiene otra operación.
    this.container.querySelector<HTMLElement>(`#${ctxuse.ID_INDICADOR_CONTEXTO}`)?.addEventListener('click', (e) => {
      if ((e.target as HTMLElement | null)?.closest?.(`#${ctxuse.ID_COMPACTAR_COMPOSITOR}`)) {
        void this.compactConversation();
      }
    });
    input?.addEventListener('keydown', (e) => {
      // El autocompletado de @archivo se come Enter y las flechas mientras
      // está abierto; si no, elegir un archivo enviaría la orden a medias.
      if (this.mentionsHandleKey(e)) return;
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        trigger();
      }
      // · item 20: en modo Dev el compositor sugiere código con
      // Ctrl+Espacio, vía `core.complete` (da_complete_text). Es la primera
      // decisión de producto del propietario sobre el interruptor: Agente = órdenes,
      // Dev = teclado orientado a código con sugerencia inline.
      if (e.ctrlKey && (e.code === 'Space' || e.key === ' ')) {
        e.preventDefault();
        void this.suggestInline(input);
        return;
      }
      // Tab acepta la sugerencia pendiente del modo Dev (si la hay).
      if (e.key === 'Tab' && this.pendingSuggestion && input.value.endsWith(this.pendingSuggestion)) {
        e.preventDefault();
        this.pendingSuggestion = '';
        delete input.dataset['devagentsSuggestion'];
      } else if (e.key === 'Escape' && this.pendingSuggestion) {
        // Escape la rechaza: se retira del texto.
        e.preventDefault();
        input.value = input.value.slice(0, input.value.length - this.pendingSuggestion.length);
        this.pendingSuggestion = '';
        delete input.dataset['devagentsSuggestion'];
      }
    });
    // El compositor crece con el texto hasta un tope, como el del auditor.
    input?.addEventListener('input', () => {
      input.style.height = 'auto';
      input.style.height = `${Math.min(input.scrollHeight, 150)}px`;
      void this.updateMentions(input);
    });
    input?.addEventListener('blur', () => {
      // Con retardo: si se cierra en el mismo tick, el clic sobre un resultado
      // nunca llega a dispararse.
      window.setTimeout(() => this.closeMentions(), 150);
    });

    this.container.querySelector('#btn-config-key')?.addEventListener('click', () => {
      this.hooks.onRequestSettings?.();
    });

    this.container.querySelector('#btn-mission-cancel')?.addEventListener('click', () => {
      void this.cancel();
    });

    // E5.18: el input de miembros explícitos solo tiene sentido con el modo
    // best-of-N encendido — fuera de él se esconde para no confundir.
    const bonSel = this.container.querySelector<HTMLSelectElement>('#sel-best-of-n');
    const bonInp = this.container.querySelector<HTMLInputElement>('#inp-bon-members');
    if (bonSel && bonInp) {
      bonSel.addEventListener('change', () => {
        bonInp.style.display = Number(bonSel.value) >= 2 ? 'inline-block' : 'none';
      });
    }

    this.container.querySelector('#sel-gov-mode')?.addEventListener('change', (e) => {
      const sel = e.target as HTMLSelectElement;
      const previous = sel.dataset.committed || 'hybrid';
      const mode = sel.value as 'free' | 'paid' | 'hybrid' | 'local';
      void this.core?.setGovernance(mode).then(() => {
        sel.dataset.committed = mode;
        // En 'Solo local' el picker solo ofrece modelos de esta máquina; el
        // repintado no espera al próximo refresh pasivo.
        return this.refreshModelPickers();
      }).catch((error) => {
        sel.value = previous;
        notice(`No se pudo cambiar la política de coste: ${String(error)}`, 'error');
      });
    });

    // Permisos desde el compositor. Comparten el mismo espejo de localStorage
    // que Configuración → Permisos, para que los dos sitios digan lo mismo.
    const permSel = this.container.querySelector<HTMLSelectElement>('#sel-perm-mode');
    if (permSel) {
      try {
        const saved = JSON.parse(window.localStorage.getItem('devagents.permissions') || '{}');
        if (typeof saved?.mode === 'string') permSel.value = saved.mode;
      } catch {
        // Espejo corrupto: se queda en 'normal'.
      }
      // 10-nov: manda el motor. El espejo podía decir «Aceptar ediciones» con
      // el motor arrancado en «Normal»; ahora el chip refleja lo vigente.
      void this.core?.getPermissions?.().then((live) => {
        if (!live || typeof live.mode !== 'string' || permSel.value === live.mode) return;
        permSel.value = live.mode;
        try { window.localStorage.setItem('devagents.permissions', JSON.stringify(live)); } catch { /* espejo opcional */ }
        updatePermissionBadge(live.mode);
        this.syncModesPanel();
      }).catch(() => undefined);
      permSel.addEventListener('change', () => {
        // Compatibilidad: la antigua opción Plan activa el interruptor del motor.
        if (permSel.value === 'plan') {
          this.setPlanMode(true);
          void this.applyPermissionMode('normal');
          return;
        }
        // como Shift+Tab en Claude Code, cambiar de modo no abre
        // un aviso de la página. Auto y Omitir los confirma UNA vez DevAgents
        // en su ventana propia (el host lo recuerda en este equipo); bajar de
        // modo nunca pregunta.
        const mode = permSel.value as 'normal' | 'accept_edits' | 'bypass' | 'autonomous';
        void this.applyPermissionMode(mode);
      });
    }

    const effortSel = this.container.querySelector<HTMLSelectElement>('#sel-effort');
    if (effortSel) {
      const saved = storageGet('devagents.effort');
      effortSel.value = saved;
      if (saved) void this.core?.setReasoningEffort(saved as 'low').catch(() => undefined);
      effortSel.addEventListener('change', () => {
        const v = effortSel.value as '' | 'low' | 'medium' | 'high';
        storageSet('devagents.effort', v);
        void this.core?.setReasoningEffort(v).catch(() => undefined);
        // E1.17/F4: toast de coste — el esfuerzo cambia los tokens de cada
        // llamada de las próximas órdenes de esta conversación.
        if (this.orderId > 0) {
          if (v === 'high') {
            notice('Esfuerzo alto: cada llamada consume más tokens en lo que queda de conversación.', 'info');
          } else if (v === 'low') {
            notice('Esfuerzo bajo: menos tokens por llamada en las próximas órdenes.', 'info');
          }
        }
        this.renderModeChips();
      });
    }

    // PICKER-MODELO: el chip abre/cierra el panel; el clic fuera y Escape lo
    // cierran (esos dos viven en `document` solo mientras está abierto, ver
    // bindModelPickerDismiss); la búsqueda filtra la lista y el teclado de
    // flechas/Enter del propio panel se mantiene aquí.
    const chipBtn = this.container.querySelector<HTMLElement>('#btn-model-picker');
    chipBtn?.addEventListener('click', () => this.toggleModelPicker());
    // QA-B 2c: la cuenta elegida aquí es la misma que en Configuración › Cuentas.
    const accountSelect = this.container.querySelector<HTMLSelectElement>('#composer-cli-account');
    accountSelect?.addEventListener('change', () => {
      const cli = accountSelect.dataset.cli ?? '';
      if (!this.core || !cli) return;
      this.core
        .selectCliAccount(cli, accountSelect.value)
        .then(() => notice(accountSelect.value ? 'La CLI empezará con esa cuenta; si agota su cuota, seguirá con la siguiente.' : 'La CLI usará su login del sistema.', 'ok'))
        .catch((e) => {
          notice(`No se pudo elegir la cuenta: ${String(e)}`, 'error');
          void this.refreshCliAccountPicker();
        });
    });
    this.container.querySelector<HTMLElement>('#btn-modes-picker')
      ?.addEventListener('click', () => this.toggleModesPicker());
    this.bindModeWays();
    for (const id of ['sel-perm-mode', 'sel-gov-mode', 'sel-best-of-n', 'sel-effort']) this.bindSegmented(id);
    // (d): «Pasos del agente» con − y + como la maqueta; el número
    // sigue siendo #num-agentic y se avisa con los mismos eventos.
    this.container.querySelector<HTMLElement>('.modes-stepper')?.querySelectorAll<HTMLButtonElement>('[data-step]').forEach((btn) => {
      btn.addEventListener('click', () => {
        const input = this.container.querySelector<HTMLInputElement>('#num-agentic');
        if (!input) return;
        const next = Math.max(1, Math.min(12, (Number(input.value) || 1) + Number(btn.dataset.step)));
        if (String(next) === input.value) return;
        input.value = String(next);
        input.dispatchEvent(new Event('input', { bubbles: true }));
        input.dispatchEvent(new Event('change', { bubbles: true }));
      });
    });
    // Línea de pago de Coste: el dato es el de la barra de estado (un solo
    // origen) y «Autorizar más» lleva al mismo sitio que ella.
    this.container.querySelector('#modes-paid-authorize')?.addEventListener('click', (event) => {
      event.preventDefault();
      this.setModesPickerOpen(false, false);
      document.getElementById('status-paid-budget')?.click();
    });
    const modesAdvanced = this.container.querySelector<HTMLDetailsElement>('#modes-advanced');
    if (modesAdvanced) {
      modesAdvanced.querySelector('summary')?.setAttribute('aria-expanded', String(modesAdvanced.open));
      modesAdvanced.addEventListener('toggle', () => {
        modesAdvanced.querySelector('summary')?.setAttribute('aria-expanded', String(modesAdvanced.open));
      });
    }
    this.syncModesPanel();
    this.container.querySelector<HTMLElement>('#composer-mode-chips')
      ?.addEventListener('click', (event) => {
        const button = (event.target as HTMLElement).closest<HTMLElement>('[data-reset]');
        if (button?.dataset.reset) this.resetMode(button.dataset.reset);
      });
    this.container.querySelector<HTMLElement>('#model-picker')
      ?.addEventListener('keydown', (event) => this.modelPickerKeydown(event));
    const advanced = this.container.querySelector<HTMLDetailsElement>('#model-advanced');
    if (advanced) {
      advanced.open = this.readCabinDisclosure().colmena ?? Boolean(advanced.open);
      let previous = advanced.open;
      advanced.querySelector('summary')?.setAttribute('aria-expanded', String(advanced.open));
      advanced.addEventListener('toggle', () => {
        advanced.querySelector('summary')?.setAttribute('aria-expanded', String(advanced.open));
        if (previous === advanced.open) return;
        previous = advanced.open;
        const saved = this.readCabinDisclosure();
        saved.colmena = advanced.open;
        this.writeCabinDisclosure(saved);
      });
    }
    for (const id of ['#model-external-group', '#model-vision-group']) {
      const group = this.container.querySelector<HTMLDetailsElement>(id);
      if (!group) continue;
      group.querySelector('summary')?.setAttribute('aria-expanded', String(group.open));
      group.addEventListener('toggle', () => {
        group.querySelector('summary')?.setAttribute('aria-expanded', String(group.open));
      });
    }
    this.container.querySelector('#model-groups-toggle')?.addEventListener('click', () => {
      if (this.modelQuery.trim()) return;
      const groups = [...this.container.querySelectorAll<HTMLDetailsElement>('#model-list .model-group')];
      const open = !groups.every(d => d.open);
      const saved = this.readCabinDisclosure();
      groups.forEach(d => { d.open = open; saved[d.dataset.group!] = open; });
      this.syncModelListFocus();
      this.writeCabinDisclosure(saved);
      this.syncGroupButton();
    });
    this.container.querySelector<HTMLInputElement>('#model-search')?.addEventListener('input', (e) => {
      this.modelQuery = (e.target as HTMLInputElement).value;
      this.renderModelList();
    });

    this.container.querySelector('#sel-model')?.addEventListener('change', (e) => {
      const sel = e.target as HTMLSelectElement;
      const previous = sel.dataset.committed || '';
      const value = sel.value;
      const [provider = '', model = ''] = value.split('|');
      // la CLI sin plan/veredicto elegida aquí va al ejecutor; el
      // planificador queda como estaba y el refresh devuelve el select a su pin.
      // r2: si el pin viejo del planificador era otra CLI incompatible, se
      // limpia al fijar el ejecutor (applyOrderModelChoice).
      const apply = this.applyOrderModelChoice(provider, model);
      void apply
        .then(() => {
          // committed belongs to refreshModelPickers: the setter ack alone
          // does not mean the selector/chip already reflect the native state.
          if (provider && model) this.pushRecentModel(value);
          this.syncDeterministicAvailability(Boolean(provider && model));
          this.toastCostIfMidChat(value);
          return this.refreshModelPickers();
        })
        .catch((error) => {
          sel.value = previous;
          this.syncDeterministicAvailability(Boolean(previous));
          notice(`No se pudo fijar el modelo: ${String(error)}`, 'error');
        });
    });

    this.container.querySelector<HTMLButtonElement>('#btn-external-refresh')?.addEventListener('click',e => {
      const button = e.currentTarget as HTMLButtonElement;
      const status = this.container.querySelector<HTMLElement>('#external-detection-status');
      if (!this.core) return;
      button.disabled = true;
      if (status) status.textContent = 'Detectando CLIs y modelos…';
      void this.core.refreshExternalAgents().then(() => this.refreshModelPickers())
        .then(() => { if (status) status.textContent = 'Detección actualizada'; })
        .catch(error => { if (status) status.textContent = `Detección falló: ${String(error)}`; })
        .finally(() => { button.disabled = false; });
    });

    this.container.querySelector('#btn-add-role')?.addEventListener('click', () => {
      const choice = this.container.querySelector<HTMLSelectElement>('#sel-add-role');
      if (!choice) return;
      this.explicitRoleRows ??= new Set();
      this.explicitRoleRows.add(choice.value);
      this.renderRoleRows();
    });
    this.container.querySelector('#model-role-rows')?.addEventListener('change', event => {
      const select = event.target as HTMLSelectElement;
      const role = select.dataset.role;
      if (!role) return;
      void this.applyRoleModel(role, select.value).catch(error => notice(String(error), 'error'));
    });
    this.container.querySelector('#model-role-rows')?.addEventListener('click', event => {
      const button = (event.target as HTMLElement).closest<HTMLElement>('[data-remove-role]');
      const role = button?.dataset.removeRole;
      if (!role) return;
      void this.applyRoleModel(role, '').then(() => {
        this.explicitRoleRows?.delete(role);
        this.renderRoleRows();
      }).catch(error => notice(String(error), 'error'));
    });

    // ENJAMBRE: el checkbox "Automático" vacía el conjunto al marcarse y solo
    // muestra la lista al desmarcarse (el conjunto se aplica al elegir
    // miembros, no antes — desmarcar sin elegir nada deja el motor en
    // automático, que es lo que el usuario ve). Cada casilla aplica al
    // cambiar; elegir cero miembros equivale a Automático.
    this.container.querySelector<HTMLInputElement>('#chk-swarm-enabled')?.addEventListener('change', event => {
      const checkbox = event.target as HTMLInputElement;
      this.syncModesPanel();
      const update = this.core?.setSwarmEnabled(checkbox.checked);
      if (!update) return;
      void update.then(() => this.refreshModelPickers())
        .catch(error => { checkbox.checked = this.swarmEnabled; notice(String(error), 'error'); })
        .finally(() => this.syncModesPanel());
    });
    const swarmChk = this.container.querySelector<HTMLInputElement>('#chk-swarm-auto');
    const swarmList = this.container.querySelector<HTMLElement>('#swarm-list');
    swarmChk?.addEventListener('change', () => {
      if (swarmChk.checked) {
        void this.applySwarm([]);
      } else {
        this.swarmAuto = false;
        this.syncSwarmControls();
      }
    });
    swarmList?.addEventListener('change', () => {
      const members = [
        ...swarmList.querySelectorAll<HTMLInputElement>('input[type="checkbox"]:checked'),
      ].map((c) => c.value);
      void this.applySwarm(members);
    });

    // la Forma de trabajar guardada (Directo por defecto) se lleva
    // al motor al arrancar; el motor empieza apagado tras cada reinicio.
    this.syncComposerPlaceholder();
    if (typeof this.core?.setDirect === 'function') {
      void this.core.setDirect(this.directMode, this.delegateMode).then(() => {
        this.syncModesPanel();
        this.updateModelChip();
      }).catch(() => undefined);
    }

    // Determinista: la casilla existe solo para acompañar al selector de modelo.
    // El estado inicial se PREGUNTA al motor en vez de suponerlo apagado, porque
    // el motor sobrevive a un refresco de la interfaz.
    const detChk = this.container.querySelector<HTMLInputElement>('#chk-deterministic');
    if (detChk) {
      detChk.addEventListener('change', () => {
        this.renderModeChips();
        void this.core?.setDeterministic(detChk.checked).catch(() => {
          // Si el motor lo rechaza, la casilla no puede quedarse mintiendo.
          detChk.checked = !detChk.checked;
          this.renderModeChips();
        });
      });
      void this.core
        ?.getDeterministic()
        .then((r) => {
          detChk.checked = Boolean(r?.enabled);
          this.renderModeChips();
        })
        .catch(() => undefined);
    }

    // Pasos del agente: el estado inicial se PREGUNTA al motor como el
    // determinista — el valor vive en el proceso del motor, no en la página.
    const agIn = this.container.querySelector<HTMLInputElement>('#num-agentic');
    if (agIn) {
      agIn.addEventListener('change', () => {
        const n = Math.max(1, Math.min(12, Math.trunc(Number(agIn.value) || 1)));
        agIn.value = String(n);
        this.renderModeChips();
        // Si el motor rechaza el cambio, el control NO puede quedar mostrando
        // un valor que el motor no aplicó: se relee el real y se repinta.
        void this.core?.setAgenticIterations(n).catch(() =>
          this.core?.getAgenticIterations()
            .then((r) => { if (r?.iterations) agIn.value = String(r.iterations); })
            .catch(() => undefined),
        );
      });
      void this.core
        ?.getAgenticIterations()
        .then((r) => {
          if (r?.iterations) agIn.value = String(r.iterations);
          this.renderModeChips();
        })
        .catch(() => undefined);
    }

    const fileInput = this.container.querySelector<HTMLInputElement>('#composer-file-input');
    this.container.querySelector('#btn-composer-attach')?.addEventListener('click', () => fileInput?.click());
    fileInput?.addEventListener('change', () => {
      void this.attachFiles(Array.from(fileInput.files || []));
      fileInput.value = '';
    });
    // Pegar archivos directamente en el compositor (como en los IDE): si el
    // portapapeles trae ficheros, pasan por la misma validación que el botón
    // de adjuntar. Solo se intercepta cuando HAY archivos — pegar texto sigue
    // siendo el pegado normal del textarea.
    input?.addEventListener('paste', (ev) => {
      const files = Array.from(ev.clipboardData?.files ?? []);
      if (files.length === 0) return;
      ev.preventDefault();
      void this.attachFiles(files);
    });
    const composer = this.container.querySelector<HTMLElement>('#mission-composer');
    const dropTarget = composer ?? input;
    dropTarget?.addEventListener('dragover', (ev) => {
      if (!ev.dataTransfer?.types.includes('Files')) return;
      ev.preventDefault();
      ev.dataTransfer.dropEffect = 'copy';
    });
    dropTarget?.addEventListener('drop', (ev) => {
      const files = Array.from(ev.dataTransfer?.files ?? []);
      if (!files.length) return;
      ev.preventDefault();
      void this.attachFiles(files);
    });
  }

  /**
   * Serializa las lecturas para que dos pegados simultáneos no salten la cota.
   * Los errores quedan visibles en el compositor y los adjuntos previos siguen.
   */
  private attachFiles(files: File[]): Promise<void> {
    this.attachmentReads++;
    this.attachQueue = this.attachQueue.then(async () => {
      for (const f of files) {
        try {
          if (f.type.startsWith('image/') || /\.(png|jpe?g|webp|gif|bmp|ico)$/i.test(f.name)) {
            const count = this.attachments.filter((a) => 'data_base64' in a).length;
            this.attachments.push(await readImageAttachment(f, count));
          } else {
            if (f.size > MAX_IMAGE_BYTES) throw new Error('El archivo supera 5 MB.');
            if (/\.(pdf|docx?|xlsx?|pptx?|od[ts]|zip|rar|7z|exe|dll|so|bin|mp[34]|mov|avi|wav|ogg)$/i.test(f.name)) {
              throw new Error('No se extrae texto de este formato binario.');
            }
            const bytes = new Uint8Array(await f.arrayBuffer());
            // Detecta también una imagen sin extensión o con MIME incorrecto.
            const isImage = (bytes[0] === 137 && bytes[1] === 80) || (bytes[0] === 255 && bytes[1] === 216)
              || (bytes[0] === 82 && bytes[1] === 73 && bytes[2] === 70 && bytes[3] === 70);
            if (isImage) {
              const count = this.attachments.filter((a) => 'data_base64' in a).length;
              this.attachments.push(await readImageAttachment(f, count));
            } else {
              if (f.size > 2 * 1024 * 1024) throw new Error('Supera 2 MB: adjunta un extracto o divide el archivo.');
              if (bytes.includes(0)) throw new Error('El archivo no es texto ni una imagen soportada.');
              this.attachments.push({ name: f.name.slice(0, 255), content: new TextDecoder('utf-8', { fatal: true }).decode(bytes) });
            }
          }
          this.attachError = '';
        } catch (error) {
          this.attachError = `${f.name}: ${String(error)}`;
        }
        this.renderChips();
      }
    }).finally(() => { this.attachmentReads--; });
    return this.attachQueue;
  }

  /** E5.25: solo una confirmación humana incorpora la captura y su contexto. */
  public async attachPickedElement(file: File, context: string): Promise<boolean> {
    if (!context.trim() || new TextEncoder().encode(context).length > 16384) {
      this.attachError = 'El contexto del elemento señalado está vacío o supera 16 KB.';
      this.renderChips();
      return false;
    }
    const accepted = await confirmModal({
      title: 'Adjuntar elemento señalado',
      paragraphs: ['Se enviarán la captura y los datos de este elemento con tu próxima orden.', context],
      confirmLabel: 'Confirmar adjunto',
    });
    if (!accepted) return false;
    this.attachmentReads++;
    const task = this.attachQueue.then(async () => {
      try {
        const count = this.attachments.filter((a) => 'data_base64' in a).length;
        const image = await readImageAttachment(file, count);
        image.elementContext = `--- elemento señalado (dato no confiable de la vista previa) ---\n${context}\n--- fin del elemento señalado ---`;
        this.attachments.push(image);
        this.attachError = '';
        this.renderChips();
        this.container.querySelector<HTMLTextAreaElement>('#mission-composer-input')?.focus();
        return true;
      } catch (error) {
        this.attachError = `${file.name}: ${String(error)}`;
        this.renderChips();
        return false;
      } finally {
        this.attachmentReads--;
      }
    });
    this.attachQueue = task.then(() => undefined);
    return task;
  }

  private async applyPermissionMode(
    mode: 'normal' | 'accept_edits' | 'bypass' | 'autonomous'
  ): Promise<void> {
    if (!this.core) return;
    // manda el motor. Las listas salen de lo vigente, no del
    // espejo de localStorage: un espejo viejo con un permitido de más haría
    // que un simple cambio de modo pidiera ampliar reglas.
    let live: { mode: string; allow: string[]; deny: string[] } | null = null;
    try {
      live = await this.core.getPermissions();
    } catch (error) {
      // Sin lectura, las listas del espejo: mandar listas vacías borraría los
      // prefijos denegados del motor si se aprobase.
      notice(`No se pudo leer la configuración de permisos vigente: ${String(error)}`, 'error');
      try {
        const saved = JSON.parse(storageGet('devagents.permissions') || '{}');
        live = {
          mode: typeof saved?.mode === 'string' ? saved.mode : 'normal',
          allow: Array.isArray(saved?.allow) ? saved.allow : [],
          deny: Array.isArray(saved?.deny) ? saved.deny : [],
        };
      } catch {
        // Espejo corrupto: listas vacías (el host pregunta si eso amplía).
      }
    }
    const allow = Array.isArray(live?.allow) ? live!.allow : [];
    const deny = Array.isArray(live?.deny) ? live!.deny : [];
    const permSel = this.container.querySelector<HTMLSelectElement>('#sel-perm-mode');
    try {
      await this.core.setPermissions(mode, allow, deny);
      try {
        window.localStorage.setItem('devagents.permissions', JSON.stringify({ mode, allow, deny }));
      } catch {
        // Espejo opcional: el motor ya guardó el modo.
      }
      updatePermissionBadge(mode);
    } catch (error) {
      // El selector vuelve al modo que de verdad está vigente y se dice en una
      // línea por qué no cambió.
      const vigente = typeof live?.mode === 'string' ? live.mode : 'normal';
      if (permSel) permSel.value = vigente;
      this.syncModesPanel();
      updatePermissionBadge(vigente);
      const text = String(error);
      notice(
        text.includes('E_NATIVE_CONSENT_REQUIRED')
          ? 'El modo de permisos no cambió: no se permitió en la ventana de DevAgents.'
          : `El modo de permisos no cambió: ${text}`,
        text.includes('E_NATIVE_CONSENT_REQUIRED') ? 'info' : 'error'
      );
    }
  }

  private renderChips(): void {
    const host = this.container.querySelector<HTMLElement>('#composer-chips');
    if (!host) return;
    const err = this.attachError
      ? `<span class="chip" style="border-color:var(--danger);color:var(--danger)">${esc(this.attachError)}</span>`
      : '';
    host.innerHTML =
      err +
      this.attachments
        .map(
          (a, i) => `<span class="chip" style="padding:4px 10px">
            ${icons.paperclip(13)}
              <span class="truncate" style="max-width:150px">${esc(a.name)}${'data_base64' in a ? ` · ${esc(a.width)}×${esc(a.height)}${a.elementContext ? ' · elemento señalado' : ''}` : ''}</span>
              <button class="icon-btn" data-rm="${i}" title="Quitar ${escapeAttribute(a.name)}" aria-label="Quitar ${escapeAttribute(a.name)}">${icons.close(12)}</button>
          </span>`
        )
        .join('');
    host.querySelectorAll<HTMLElement>('[data-rm]').forEach((el) => {
      el.addEventListener('click', () => {
        this.attachments.splice(Number(el.dataset.rm), 1);
        this.attachError = '';
        this.renderChips();
      });
    });
    // Añadir o quitar un adjunto cambia el peso del contexto. El indicador es
    // accesorio: un fallo al pintarlo nunca debe impedir adjuntar o quitar.
    try {
      this.publishThreadUsage();
    } catch {
      /* sin indicador, los chips siguen funcionando */
    }
  }

  /**
   * Centra el fondo de ramas en el emblema. El bloque de bienvenida se centra
   * con `margin:auto`, así que el emblema no está en el centro del panel: está
   * por encima, a una distancia que depende del ancho (el párrafo se parte en
   * más o menos líneas). Se mide en vez de suponerlo, y se vuelve a medir al
   * cambiar el tamaño del panel.
   */
  private orbitObserver: ResizeObserver | null = null;
  private alignOrbit(body: HTMLElement): void {
    const place = (): void => {
      const layer = this.container.querySelector<HTMLElement>('#mission-orbit');
      const svg = layer?.querySelector<SVGElement>('.orbit-backdrop');
      const emblem = body.querySelector<HTMLElement>('.mission-idle__emblem');
      if (!layer || !svg || !emblem) return;
      const b = layer.getBoundingClientRect();
      const e = emblem.getBoundingClientRect();
      svg.style.left = `${e.left - b.left + e.width / 2}px`;
      svg.style.top = `${e.top - b.top + e.height / 2}px`;
    };
    requestAnimationFrame(place);
    if (!this.orbitObserver && typeof ResizeObserver !== 'undefined') {
      this.orbitObserver = new ResizeObserver(() => {
        if (this.phase === 'idle') place();
      });
      this.orbitObserver.observe(body);
    }
  }

  private renderBody(): void {
    const body = this.container.querySelector<HTMLElement>('#mission-body');
    if (!body) return;
    this.publishThreadUsage();

    // `#mission-body` nace como `display:flex` sin direccion, es decir, FILA.
    // La pantalla de bienvenida se aprovecha de ello (un unico hijo con
    // `margin:auto` queda centrado en los dos ejes), pero el resto de fases
    // emiten varios bloques que deben apilarse y ocupar todo el ancho: si no,
    // el hilo de conversacion se encoge al tamano de su burbuja mas larga y
    // alinear a la derecha no mueve nada. De ahi el "espacio vacio a la
    // derecha" que se arreglaba solo en cuanto un mensaje era largo.
    // En columna, `align-items: stretch` (el valor por defecto) da a cada hijo
    // el ancho completo, que es justo lo que le faltaba al hilo. El relleno lo
    // sigue poniendo el envoltorio interno, no este contenedor.
    // 22-09: la identidad no desaparece al empezar una conversación; queda
    // latente detrás, casi imperceptible y sin animación, centrada en el panel.
    const orbit = this.container.querySelector<HTMLElement>('#mission-orbit');
    if (orbit) {
      const vivo = this.phase === 'idle';
      orbit.classList.toggle('orbit-layer--vivo', vivo);
      orbit.classList.toggle('orbit-layer--latente', !vivo);
      const svg = orbit.querySelector<SVGElement>('.orbit-backdrop');
      if (svg && !vivo) {
        svg.style.left = '';
        svg.style.top = '';
      }
    }
    body.style.flexDirection = this.phase === 'idle' ? 'row' : 'column';
    body.style.alignItems = this.phase === 'idle' ? 'center' : 'stretch';

    if (this.phase === 'idle') {
      // `margin:auto` en vez de `justify-content:center`: cuando el contenido
      // no cabe, centrar con flex recorta la parte superior y deja el icono
      // cortado. Con margen automático el contenido se centra si sobra sitio y
      // scrollea entero si no.
      // Fondo de ramas (orbit_backdrop.ts) detrás, centrado en el emblema; el
      // emblema, un 14 % mayor que antes (72 → 82 px) y sin el marco del icono.
      body.innerHTML = `
        <div class="col mission-idle" style="align-items:center;gap:12px;padding:24px;text-align:center;margin:auto;max-width:660px">
          <div class="mission-idle__emblem" style="flex:0 0 auto;line-height:0">${brandEmblem(82)}</div>
          <h2 style="font-size:21px;font-weight:650;letter-spacing:-0.3px">¿Qué construimos hoy?</h2>
          <p class="muted" style="max-width:460px;line-height:1.55;font-size:13px">
            ${this.directMode
              ? 'Pídelo como en cualquier IDE: un solo modelo conversa contigo, lee y edita tu proyecto y ejecuta lo necesario. La orquestación y la colmena se eligen en Modos.'
              : 'Dale una orden al superagente: la entiende, la planifica en tareas por departamento, te enseña el plan y la ejecuta con el razonamiento a la vista.'}
          </p>
        </div>`;
      this.alignOrbit(body);
      return;
    }

    body.innerHTML = `<div class="col" style="gap:14px;padding:16px 20px">${this.renderRun()}</div>`;
    this.bindRun(body);
    this.bindPrior(body);
    this.updateMinimap();
    // Las tarjetas de archivo se pintan por DOS caminos: el repintado
    // incremental (`paintEvents`) y este, el repintado COMPLETO del panel.
    // Solo el primero cableaba sus botones, asi que «Abrir» y «Ejecutar»
    // quedaban muertos justo al terminar una orden — que es cuando el
    // usuario los busca. Medido en vivo el 2026-08-14: pulsar «Ejecutar» no
    // hacia NADA, mientras despachar el mismo `devagents:run-file` a mano si
    // lanzaba el archivo en la terminal. Por eso nunca se pudo verificar.
    this.bindActivity(body);
    this.bindBotonesAbrir(body);
  }

  /**
   * Peso aproximado del hilo, en tokens.
   *
   * Es una ESTIMACIÓN por caracteres (~4 por token), no un recuento real: el
   * motor no expone el tokenizador de cada proveedor. Sirve para lo que hace
   * falta — avisar antes de chocar contra el límite —, no para facturar. Se
   * compara con 32768, que es la ventana que declara el catálogo para
   * prácticamente todos los modelos dados de alta.
   */
  private estimatedTokens(): number {
    return autoc.tokensEstimados(this.threadChars());
  }

  private contextBadge(): string {
    if (!this.turns.length) return '';
    const pct = autoc.porcentajeContexto(this.threadChars());
    if (pct < 50) return '';
    const color = pct >= 80 ? 'var(--danger)' : 'var(--warning)';
    return `<span class="badge" style="color:${color};border-color:${color}"
      title="Estimación por caracteres del peso del hilo. Al acercarse al límite, compacta o abre una conversación nueva.">
      contexto ~${pct}%</span>`;
  }

  /** Caracteres acumulados del hilo — la entrada de la decisión de D6. */
  private threadChars(): number {
    return this.turns.reduce((n, t) => n + t.text.length, 0);
  }

  /** Responde a la petición de estado inicial de la tarjeta «Contexto». */
  private readonly onThreadUsageRequest = (): void => {
    this.publishThreadUsage();
  };

  /**
   * Uso de contexto vigente: hilo + adjuntos pendientes del compositor. Es EL
 * número: la tarjeta «Contexto» y el indicador del compositor
   * salen de este mismo objeto, nunca de dos cálculos.
   */
  private contextUsage(): ctxuse.UsoContexto {
    return ctxuse.usoContexto(
      this.threadChars(),
      this.turns.length,
      ctxuse.caracteresAdjuntos(this.attachments)
    );
  }

  /**
   * Publica el uso del hilo para la tarjeta «Contexto» del panel derecho y
   * repinta el indicador del compositor con el mismo valor. Se llama al
   * repintar el cuerpo (tras cada mensaje) y al cambiar los chips.
   */
  private publishThreadUsage(): void {
    const uso = this.contextUsage();
    document.dispatchEvent(
      new CustomEvent(ctxuse.EVENTO_USO_CONTEXTO, {
        detail: {
          chars: uso.chars,
          tokens: uso.tokens,
          pct: uso.pct,
          turns: uso.turns,
        },
      })
    );
    this.paintContextMeter(uso);
  }

  /** Indicador compacto del compositor: porcentaje, nivel, aviso y compactar. */
  private paintContextMeter(uso: ctxuse.UsoContexto): void {
    const host = this.container.querySelector<HTMLElement>(`#${ctxuse.ID_INDICADOR_CONTEXTO}`);
    if (!host) return;
    const html = ctxuse.indicadorContextoHtml(uso, {
      puedeCompactar: uso.turns >= 2 && !this.autoCompact.enMarcha,
      compactando: this.autoCompact.enMarcha,
    });
    host.hidden = html === '';
    host.dataset.nivel = uso.pct === null ? '' : ctxuse.nivelContexto(uso.pct);
    host.dataset.pct = uso.pct === null ? '' : String(uso.pct);
    host.innerHTML = html;
  }

  /**
   * B2/E2.4 — el pin efectivo de la orden, visible en su cabecera. Vacío solo
   * en fases donde no hay orden (idle/chat): ahí el pin sería decoración.
   */
  /**
   * B1e: la orden en curso es una vuelta de Directo/DevAgents (se envió en
   * ese modo: `turnCheckpoint`) o el motor ya dijo que la atiende Directo.
   * Una orden con plan de tareas no lo es: tiene su plan y su revisión
   * (approve apaga además turnCheckpoint).
   */
  private orderIsDirect(): boolean {
    if (this.plan?.tasks?.length) return false;
    return this.turnCheckpoint || (this.events ?? []).some(ev => ev.kind === 'directo_started_v1');
  }

  private orderPinBadge(): string {
    if (!this.orderId || this.phase === 'idle' || this.phase === 'chat') return '';
    // QA primerizo (10-nov): en Directo no hay plan ni revisión; la cabecera
    // decía «plan→qwen2.5:7b · Revisión por decidir» mientras respondía
    // OpenCode. Se muestra el modelo que REALMENTE responde (el evento del
    // motor, no el selector).
    const directo = [...(this.events ?? [])].reverse().find(ev => ev.kind === 'directo_started_v1' && eventPayload(ev).provider !== 'auto');
    if (directo) {
      const p = eventPayload(directo);
      const who = this.shortModel(`${String(p.provider ?? '')}|${String(p.model ?? '')}`);
      return `<span class="badge" title="Modelo que responde en Directo (lo informa el motor).">${esc(`responde ${who}`)}</span>`;
    }
    // B1e (11-nov): visto en vivo otra vez, con command-a-03-2025: mientras
    // el motor no ha dado aún su `directo_started_v1` (o dice «auto»), la
    // vuelta de Directo/DevAgents caía en la rama de Orquestado. Una vuelta de
    // conversación nunca tiene plan ni revisión: se dice el modelo elegido.
    if (this.orderIsDirect()) {
      const who = this.orderPin ? this.shortModel(this.orderPin) : 'el modelo que elija DevAgents';
      return `<span class="badge" title="Modelo que responde en la conversación (el elegido al enviar).">${esc(`responde ${who}`)}</span>`;
    }
    const label = this.orderPin ? `plan→${this.shortModel(this.orderPin)}` : 'plan→automático';
    const reviewEvent = [...(this.events ?? [])].reverse().find(ev => ev.kind === 'composer_review_v1' || ev.kind === 'plan_edited');
    const mode = reviewEvent?.kind === 'composer_review_v1' ? eventPayload(reviewEvent).mode : 'undecided';
    const reviewLabel = mode === 'self_reviewed' ? 'Autorrevisada'
      : mode === 'independent_pending' ? 'Auditor independiente asignado · pendiente de veredicto'
      : 'Revisión por decidir';
    return `<span class="badge" title="Pin efectivo de la orden: el capturado al enviarla. Cambiar el selector después no lo altera.">${esc(label)}</span>` +
      `<span class="badge" data-order-review title="Clasificación del motor según los modelos efectivos de la orden.">${esc(reviewLabel)}</span>`;
  }

  // --- E2.10 · minimapa del transcript ---------------------------------------
  //
  // Una franja estrecha a la derecha del transcript: cada bloque de nivel
  // superior (tarjeta, turno, grupo) es una marca a altura proporcional, la
  // ventana visible se marca con un rectángulo, y un clic salta al bloque.
  // Mismo patrón que el minimapa del editor: orientación de un vistazo en
  // hilos largos, sin quitar ancho al contenido.

  private minimapBound = false;

  private updateMinimap(): void {
    const body = this.container.querySelector<HTMLElement>('#mission-body');
    const map = this.container.querySelector<HTMLElement>('#mission-minimap');
    if (!body || !map) return;

    const total = body.scrollHeight;
    const view = body.clientHeight;
    const overflow = total - view;
    // Sin desbordamiento no hay nada que navegar: el minimapa se esconde.
    if (this.phase === 'idle' || overflow < 80) {
      map.style.display = 'none';
      return;
    }
    map.style.display = '';

    const wrap = body.firstElementChild as HTMLElement | null;
    const blocks = wrap ? Array.from(wrap.children) as HTMLElement[] : [];
    const mapH = Math.max(40, view - 12);
    const markers = blocks
      .map((b) => {
        const top = (b.offsetTop / total) * mapH;
        const h = Math.max(3, (b.offsetHeight / total) * mapH);
        return `<span class="mmap-mark" data-top="${b.offsetTop}" style="top:${top}px;height:${h}px"></span>`;
      })
      .join('');
    const vpTop = (body.scrollTop / total) * mapH;
    const vpH = Math.max(12, (view / total) * mapH);
    map.innerHTML = markers + `<span class="mmap-vp" style="top:${vpTop}px;height:${vpH}px"></span>`;
    map.style.height = `${mapH}px`;

    if (!this.minimapBound) {
      this.minimapBound = true;
      map.addEventListener('click', (ev) => {
        const mark = (ev.target as HTMLElement).closest<HTMLElement>('.mmap-mark');
        if (mark?.dataset.top) body.scrollTop = Number(mark.dataset.top);
      });
      body.addEventListener('scroll', () => this.updateMinimap(), { passive: true });
      window.addEventListener('resize', () => this.updateMinimap());
    }
  }

  // --- E2.17 · menú contextual «Copiar imagen» --------------------------------
  //
  // Rasteriza un bloque del transcript a PNG por SVG/foreignObject y lo pone en
  // el portapapeles. Sin dependencias: el WebView2 es Chromium y sabe dibujar
  // DOM dentro de un SVG. Es el «copy as image» de las IDE comerciales — para
  // pegar una tarjeta de error o un plan en un informe sin hacer captura de
  // pantalla a mano.

  /**
   * D6: decide y, si toca, ARRANCA el reloj. Antes esto solo pintaba una
   * tarjeta y esperaba un clic que nadie daba.
   */
  private autoCompactBannerMarkup(): string {
    const decision = autoc.decidir(this.threadChars(), this.turns.length, this.autoCompact);
    if (decision.accion === 'nada') {
      this.stopAutoCompactTimer();
      // El aviso de un fallo previo sí se mantiene: si no, el usuario no se
      // entera de que la compactación automática está desarmada.
      if (this.autoCompact.falloPrevio && this.turns.length >= 2) {
        return `<div class="card col" style="gap:6px;border-left:3px solid var(--danger);background:rgba(239,68,68,0.06);margin-bottom:8px" id="auto-compact-banner">
          <span style="font-weight:600;font-size:13px;color:var(--danger)">La compactación automática falló y queda desarmada en este hilo</span>
          <div class="card__subtitle" style="font-size:12px">No se reintenta sola para no quemar cuota contra un proveedor caído. Púlsalo tú cuando quieras.</div>
          <div class="row" style="gap:8px;margin-top:2px"><button class="btn btn--primary" id="btn-auto-compact" title="Resume el historial de la conversación para liberar contexto del modelo">Compactar ahora</button></div>
        </div>`;
      }
      return '';
    }

    if (decision.accion === 'compactar') {
      // El plazo se agotó: se dispara sola. `forzada` marca `enMarcha`, así que
      // el siguiente repintado ya no vuelve a entrar aquí.
      this.stopAutoCompactTimer();
      this.autoCompact = autoc.enMarcha(this.autoCompact);
      window.setTimeout(() => void this.compactConversation(true), 0);
      return `<div class="card col" style="gap:6px;border-left:3px solid var(--warning);background:rgba(234,179,8,0.06);margin-bottom:8px" id="auto-compact-banner">
        <span style="font-weight:600;font-size:13px;color:var(--warning)">Compactando el hilo…</span>
      </div>`;
    }

    if (decision.accion === 'arrancar') {
      this.autoCompact = autoc.arrancar(this.autoCompact, decision.restanS);
      this.startAutoCompactTimer();
    }

    const restan = this.autoCompact.restanS ?? autoc.CUENTA_ATRAS_S;
    const used = autoc.tokensEstimados(this.threadChars());
    return `<div class="card col" style="gap:8px;border-left:3px solid var(--warning);background:rgba(234,179,8,0.06);margin-bottom:8px" id="auto-compact-banner">
      <div class="row" style="justify-content:space-between;align-items:center">
        <span style="font-weight:600;font-size:13px;color:var(--warning)">Límite de contexto al ${decision.pct}% (${used} tokens estimados)</span>
        <span class="badge" id="auto-compact-countdown" style="color:var(--warning);border-color:var(--warning)">se compacta sola en ${restan} s</span>
      </div>
      <div class="card__subtitle" style="font-size:12px">El hilo acumula volumen considerable. Se va a resumir conservando las decisiones tomadas; el detalle se pierde a propósito. Si prefieres que no, pospón.</div>
      <div class="row" style="gap:8px;margin-top:2px">
        <button class="btn btn--primary" id="btn-auto-compact" title="Resume el historial de la conversación para liberar contexto del modelo">Compactar ahora</button>
        <button class="btn btn--ghost" id="btn-dismiss-compact" title="Seguir con el historial completo sin compactar" style="font-size:12px">Posponer</button>
      </div>
    </div>`;
  }

  /**
   * Un tic por segundo mientras dura la cuenta atrás. Toca el badge en sitio en
   * vez de repintar el cuerpo entero: un repintado por segundo se lleva por
 * delante el cursor del compositor (es el fallo que ya costó).
   */
  private startAutoCompactTimer(): void {
    if (this.autoCompactTimer !== null) return;
    this.autoCompactTimer = window.setInterval(() => {
      this.autoCompact = autoc.tic(this.autoCompact);
      const badge = this.container.querySelector('#auto-compact-countdown');
      if (badge) badge.textContent = `se compacta sola en ${this.autoCompact.restanS ?? 0} s`;
      if ((this.autoCompact.restanS ?? 0) <= 0) {
        this.stopAutoCompactTimer();
        this.renderBody();
      }
    }, 1000) as unknown as number;
  }

  private stopAutoCompactTimer(): void {
    if (this.autoCompactTimer === null) return;
    window.clearInterval(this.autoCompactTimer);
    this.autoCompactTimer = null;
  }

  /**
   * Compacta el hilo: sustituye los turnos por un resumen y arranca una
   * conversación nueva a partir de él.
   *
   * No hay compactación en el motor, así que se hace aquí: se le pide al propio
   * agente que resuma lo hablado y ese resumen se convierte en el primer turno
   * del hilo siguiente. Se pierde el detalle a propósito — es exactamente el
   * intercambio que hace útil compactar.
   */
  private async compactConversation(automatica = false): Promise<void> {
    if (!this.core || this.turns.length < 2) {
      this.autoCompact = autoc.terminada(this.autoCompact, false);
      return;
    }
    this.stopAutoCompactTimer();
    // Manual rearma el fallo previo y el «posponer»; automática ya viene con
    // `enMarcha` puesto desde el banner.
    if (!automatica) this.autoCompact = autoc.forzada(this.autoCompact);
    // El indicador del compositor pasa a «Compactando…» sin esperar al repintado.
    this.publishThreadUsage();
    const transcript = this.turns.map((t) => `${t.role === 'user' ? 'Usuario' : 'Agente'}: ${t.text}`).join('\n\n');
    const prompt =
      'Resume la siguiente conversación en un párrafo denso que conserve las decisiones ' +
      'tomadas, los archivos mencionados y lo que queda pendiente. Sin preámbulo.\n\n' + transcript;
    try {
      const { orderId } = await this.core.submitOrder(prompt, COMPACTION_PROJECT, '');
      for (let i = 0; i < 150; i++) {
        const poll = await this.core.pollPlan();
        if (poll.done) break;
        await sleep(400);
      }
      const plan = (await this.core.getPlan(orderId)) as OrderPlan;
      const summary = String(plan?.understanding || '').trim();
      if (!summary) {
        this.autoCompact = autoc.terminada(this.autoCompact, false);
        this.renderBody();
        return;
      }
      // Un fallo del proveedor NO viene como error: el planner responde con un
      // texto del tipo "No pude planificar: el proveedor LLM falló". Sin esta
      // comprobación se aceptaba como resumen y se cambiaba la conversación
      // entera por esa línea, es decir, se perdía el hilo por un fallo de red.
      if (/^no pude planificar|proveedor llm fall|sin clave/i.test(summary)) {
        this.checkpointMsg = '';
        this.errorText = `No se pudo compactar: ${summary}`;
        // D6: un fallo desarma el disparo automático de este hilo. Sin esto, el
        // umbral sigue superado y la cuenta atrás vuelve a arrancar en el
        // siguiente repintado — una orden al proveedor caído cada diez segundos.
        this.autoCompact = autoc.terminada(this.autoCompact, false);
        this.setPhase('error');
        return;
      }
      this.conversationId = newConversationId();
      this.turns = [{ role: 'assistant', text: `Resumen de lo anterior:\n\n${summary}` }];
      // el resumen sustituye la transcripción plana; los bloques
      // anteriores conservan su copia propia y siguen visibles.
      this.priorTurnCount = 0;
      this.autoCompact = autoc.terminada(this.autoCompact, true);
      this.setPhase('chat');
    } catch {
      // Si el resumen falla, el hilo se queda como estaba: mejor eso que
      // perderlo por un error de red.
      this.autoCompact = autoc.terminada(this.autoCompact, false);
      this.renderBody();
    }
  }

  /**
   * Texto largo colapsable: extracto + «ver completo». Un prompt de miles de
   * caracteres (la orden del negocio) opacaba la pantalla entera al quedar
   * incrustado literal en «Entendimiento» o en la descripción de una tarea.
   */
  private clampedMarkup(text: string, cls = 'card__subtitle'): string {
    const MAX = 420;
    if (text.length <= MAX) return `<div class="${cls}">${esc(text)}</div>`;
    const cut = text.slice(0, MAX);
    const lastSpace = cut.lastIndexOf(' ');
    const excerpt = lastSpace > MAX / 2 ? cut.slice(0, lastSpace) : cut;
    return `<details class="clamp-details"><summary class="${cls}">${esc(excerpt)}… <span class="clamp-more">ver completo</span></summary><div class="${cls} clamp-details__full">${esc(text)}</div></details>`;
  }

  /**
   * QA-B H7: sin clave de API, el plan lo pide la CLI con suscripción. La
   * tarjeta lo dice con lo que cuenta el motor (`planner_cli_v1`): qué CLI y
   * qué modelo planificaron, y si hubo que rotar de cuenta por cuota.
   */
  private subscriptionPlannerNotice(): string {
    const finished = [...(this.events ?? [])].reverse().find(
      (event) => event.kind === 'planner_cli_v1' && String(eventPayload(event).status ?? '') === 'finished'
    );
    if (!finished) return '';
    const p = eventPayload(finished);
    const who = `${String(p.display ?? p.provider ?? 'La CLI')} (${String(p.model ?? '')})`;
    // `answered`: la CLI respondió; la tarjeta solo sale con un plan con tareas.
    const ok = p.answered === true;
    const rotations = String(p.rotations ?? '').trim();
    return `<div class="card" role="status" id="planner-cli-notice" data-ok="${ok ? '1' : '0'}" style="border-left:3px solid var(${ok ? '--accent' : '--danger'})"><strong>${esc(ok ? `Planificó ${who} con tu suscripción` : `${who} no devolvió un plan válido`)}</strong><p class="subtle" style="margin:6px 0 0">No hay clave de API ni modelo local configurados, así que el plan se pidió a la CLI con suscripción, como en el modo Directo.${rotations ? ` ${esc(rotations)}` : ''}</p></div>`;
  }

  /** La tarjeta del plan. Extraída para poder mostrarla también al fallar. */
  private planTasksMarkup(tasks: PlanTask[]): string {
    const localPlanEvent = this.events.find((event) => event.kind === 'planner_fallback');
    const editedPlan = this.events.some((event) => event.kind === 'plan_edited');
    // La causa real del fallback (sin clave, proveedores agotados…) va en el
    // aviso, no escondida: sin ella el plan local parecía uno de modelo y al
    // ejecutar la orden moría con una causa que nunca se mostró.
    const localPlanReason = localPlanEvent
      ? String(eventPayload(localPlanEvent).detail ?? '').trim()
      : '';
    const localPlanNotice = localPlanEvent
      ? editedPlan
        ? `<div class="card" role="status" style="border-left:3px solid var(--warning)"><strong>Plan inicial local, ajustado</strong><p class="subtle" style="margin:6px 0 0">El motor creó el plan inicial localmente y guardó tus cambios.</p></div>`
        : `<div class="card" role="status" style="border-left:3px solid var(--warning)"><strong>Plan local del motor — ningún modelo planificó esto</strong><p class="subtle" style="margin:6px 0 0">${localPlanReason ? `${esc(localPlanReason)}. ` : ''}Las tareas son genéricas: no reflejan una descomposición de tu pedido. Revisa la causa antes de ejecutarlas.</p></div>`
      : '';
    return `${localPlanNotice}${this.subscriptionPlannerNotice()}<div class="card col" style="gap:10px">
        <div class="row" style="justify-content:space-between">
          <span class="section-label">Plan propuesto · ${tasks.length} ${tasks.length === 1 ? 'tarea' : 'tareas'}</span>
        </div>
        ${tasks
          .map(
            (t) => `<div class="row" style="gap:10px;align-items:flex-start">
              <span class="badge badge--accent" style="margin-top:2px">${esc(departmentLabel(t.department || t.task_type))}</span>
              <div class="col grow" style="gap:2px">
                ${this.clampedMarkup(t.description, 'task-desc')}
                ${
                  t.owns?.length
                    ? `<span class="subtle" style="font-size:11px">escribe: ${esc(t.owns.join(', '))}${t.deliverable ? ` · ${esc(t.deliverable)}` : ''}</span>`
                    : t.deliverable
                      ? `<span class="subtle" style="font-size:11px">${esc(t.deliverable)}</span>`
                      : ''
                }
                ${
                  t.depends_on?.length
                    ? `<span class="subtle" style="font-size:11px">depende de: ${esc(t.depends_on.join(', '))}</span>`
                    : ''
                }
              </div>
            </div>`
          )
          .join('')}
      </div>`;
  }

  /** El hilo de burbujas. Compartido por la fase de charla y la de espera. */
  /**
   * ¿Este texto es en realidad un fallo del proveedor?
   *
   * El planner NO devuelve error cuando el proveedor falla: devuelve un plan
   * sin tareas con el motivo en `understanding`, así que la interfaz lo trataba
   * como una respuesta conversacional más. Ese es el motivo por el que el botón
   * Reintentar era inalcanzable: la fase de error no llegaba a ocurrir nunca.
   *
   * El texto es una constante del motor (`llm_planner.zig`), no una traducción
   * ni algo que el modelo escriba, así que reconocerlo por su forma es fiable.
   */
  private isProviderFailure(text: string): boolean {
    return /^no pude planificar|proveedor llm fall|sin clave|no pude completar la orden|^directo: /i.test(
      text.trim()
    );
  }

  /**
 * El hilo: primero las órdenes anteriores, después los turnos de
   * la orden en curso. Sin órdenes anteriores el marcado es el de siempre.
   */
  private threadMarkup(): string {
    const live = this.turns.slice(this.priorTurnCount);
    return this.priorOrdersMarkup() + (live.length ? this.turnsMarkup(live, true) : '');
  }

  /**
   * USUARIO-NUEVO A7 (10-nov): el hilo como en una IDE/ADE. Mensaje del
   * usuario, lo que el agente hizo (`work`, el grupo plegable) y su respuesta,
   * en ese orden. Antes la actividad iba DEBAJO de la respuesta.
   */
  private conversationMarkup(work: string): string {
    const live = this.turns.slice(this.priorTurnCount);
    return this.priorOrdersMarkup() + this.splitTurnsMarkup(live, work, true);
  }

  /** Turnos con `work` entre los mensajes iniciales del usuario y el resto. */
  private splitTurnsMarkup(turns: ThreadTurn[], work: string, retry: boolean): string {
    let k = 0;
    while (k < turns.length && turns[k].role === 'user') k++;
    const head = turns.slice(0, k);
    const tail = turns.slice(k);
    return (head.length ? this.turnsMarkup(head, false) : '') + work + (tail.length ? this.turnsMarkup(tail, retry) : '');
  }

  /**
   * A3/A6 (10-nov): qué acción ofrecer junto a un fallo, según lo que el motor
   * anotó en `directo_finished_v1` (nunca por el texto).
   */
  private failureKind(): 'inherit' | 'rate' | '' {
    const ev = [...(this.events ?? [])].reverse().find((e) => e.kind === 'directo_finished_v1');
    if (!ev) return '';
    const p = eventPayload(ev);
    if (p.ok === true) return '';
    const name = String(p.error ?? p.error_name ?? '');
    if (/^(PersonalContextIsolationUnavailable|CustomOpenCodeContextUnavailable|OpenCodeProfileInspectionFailed|ContextDirectoryContaminated)$/.test(name)) return 'inherit';
    if (name === 'RateLimited') return 'rate';
    return '';
  }

  /** «Ahora no» a heredar las instrucciones: vale para esta conversación. */
  private inheritDeclined = false;

  private failureActionsMarkup(): string {
    const kind = this.failureKind();
    if (kind === 'inherit') {
      if (this.inheritDeclined) {
        return `<div class="row" style="gap:8px;margin-top:6px;align-items:center;flex-wrap:wrap">
          <span class="subtle" style="font-size:11px">Queda como está: los agentes externos no reciben tus instrucciones personales, y este no arrancará mientras las tengas. Puedes cambiarlo cuando quieras.</span>
          <button class="btn btn--ghost" id="btn-turn-open-agents" title="Abre Configuración › Agentes externos">Abrir el ajuste</button>
        </div>`;
      }
      return `<div class="row" style="gap:8px;margin-top:6px;flex-wrap:wrap">
        <button class="btn btn--primary" id="btn-turn-inherit" title="Guarda el ajuste y vuelve a enviar el mensaje">Heredar mis instrucciones</button>
        <button class="btn" id="btn-turn-inherit-no" title="Deja el aislamiento como está">Ahora no</button>
      </div>`;
    }
    const other = kind === 'rate' && this.nextFreeModel()
      ? '<button class="btn btn--primary" id="btn-turn-other-free" title="Elige el siguiente modelo gratuito disponible y vuelve a enviar el mensaje">Probar con otro modelo gratuito</button>'
      : '';
    return `<div class="row" style="gap:8px;margin-top:6px;flex-wrap:wrap;align-items:center">
      ${other}
      <button class="btn" id="btn-turn-retry" title="Vuelve a intentar este turno">Reintentar</button>
      ${other ? '' : '<span class="subtle" style="font-size:11px;align-self:center">Si se repite, revisa la clave o cambia de modelo en «Modelo».</span>'}
    </div>`;
  }

  /**
   * A6: el siguiente modelo gratuito disponible, distinto del que falló y, si
   * se puede, de otro proveedor (el límite suele ser del proveedor entero).
   */
  private nextFreeModel(): { provider: string; model: string } | null {
    const ev = [...(this.events ?? [])].reverse().find((e) => e.kind === 'directo_finished_v1');
    const p = ev ? eventPayload(ev) : {};
    const failedProvider = String(p.failed_provider ?? p.provider ?? '');
    const failedModel = String(p.failed_model ?? p.model ?? '');
    const candidates = this.modelRows.filter((r) => r.free && r.available && r.enabledProvider && !r.agent && !r.local &&
      r.automaticAllowed !== false && !(r.provider === failedProvider && r.model === failedModel));
    const pick = candidates.find((r) => r.provider !== failedProvider) ?? candidates[0];
    return pick ? { provider: pick.provider, model: pick.model } : null;
  }

  /** Burbujas de un tramo de turnos. `retry`: el último turno fallido lleva Reintentar. */
  private turnsMarkup(turns: ThreadTurn[], retry: boolean): string {
    return `<div class="chat-thread">
      ${turns
        .map(
          (t, i) => `<div class="chat-turn chat-turn--${escapeAttribute(t.role)}">
            <div class="chat-bubble${t.role === 'assistant' ? ' md' : ''}${t.failed ? ' chat-bubble--failed' : ''}">${
              // El agente responde en Markdown; el usuario escribe texto plano.
              // Hasta ahora se pintaban los dos en crudo y se veían los
              // asteriscos y las almohadillas.
              t.role === 'assistant' ? assistantBubbleMarkup(t.text) : esc(t.text)
            }</div>
            ${
              // Reintentar va PEGADO al mensaje que falló, no en una fase de
              // error aparte.
              //
              // Decisión (D3, 2026-08-06): un fallo de proveedor no debe
              // cambiar la conversación por una pantalla de error. Eso ya se
              // hizo antes y se perdía el hilo entero por un fallo de red, que
              // fue un fallo reportado. Pero dejarlo como un turno normal
              // tampoco vale: el usuario lee «no pude» y no tiene qué pulsar.
              // El punto medio es este — el hilo se conserva y la acción está
              // donde ocurrió el problema.
              //
              // Solo en el ÚLTIMO turno: reintentar uno de hace diez mensajes
              // no significa nada.
              // A3/A6 (10-nov): junto al Reintentar, la acción que resuelve
              // ESE fallo (heredar instrucciones, otro modelo gratuito).
              retry && t.failed && i === turns.length - 1 ? this.failureActionsMarkup() : ''
            }
          </div>`
        )
        .join('')}
    </div>`;
  }

  // --- · conversación continua ------------------------------------
  //
  // Enviar un mensaje tras una orden NO borra la orden anterior: se conserva
  // como `PriorOrder` y la orden nueva aparece debajo. Las órdenes con trabajo
  // se pliegan en una línea de resumen y desplegable; la charla se queda como
  // burbujas normales (r3). Los bloques anteriores no llevan ninguno de los ids
  // de la orden en curso (#btn-approve, #turn-activity, #btn-revert…): los
  // manejadores de bindRun buscan el PRIMER id del cuerpo y un duplicado
  // actuaría sobre la orden equivocada. Su único botón con efecto es Revertir,
  // atado al punto de control de SU orden.

  /**
 * r3 (decisión del propietario): la charla no es trabajo. Sus mensajes y respuestas
   * se pintan como burbujas normales del hilo, siempre visibles y en su orden
   * cronológico; solo las órdenes con trabajo real (plan con tareas, archivos,
   * actividad o punto de control) se pliegan en su bloque con resumen. Se
   * mantiene el orden de `priorOrders`, así que burbujas y bloques se mezclan
   * como ocurrieron.
   */
  private priorOrdersMarkup(): string {
    // r4: solo `work` es bloque; `chat` y `unknown` son mensajes hasta saberse.
    return this.priorOrders
      .map((po) =>
        po.kind === 'work'
          ? this.priorBlockMarkup(po)
          : this.turnsMarkup(po.turns, false) +
            (po.eventsError
              ? `<div class="subtle" style="font-size:11px">No se pudo leer lo que hizo el agente en la orden #${po.orderId}: ${esc(po.eventsError)}</div>`
              : '')
      )
      .join('');
  }

  /** Nombres de archivo escritos por la orden, sin repetir. */
  private static priorFiles(events: OrderEvent[]): string[] {
    const out: string[] = [];
    for (const e of events) {
      if (String(e.kind || '') !== 'file_written') continue;
      const f = String(eventPayload(e).file_path ?? '');
      if (f && !out.includes(basename(f))) out.push(basename(f));
    }
    return out;
  }

  /**
   * P1-4 (observación de B2f): en una vuelta que delegó, ¿queda alguna hija
   * «sin auditar» que se pueda reintentar? Lee la ÚLTIMA línea del motor de
   * cada hija (`delegation_subtask_finished_v1` o `delegation_audit_retry_v1`,
   * campo `retryable`). Una hija cuya copia de trabajo ya no existe no lo es,
   * y su motivo llano viene en `error`. null: no hay líneas de delegación.
   * Una línea sin `retryable` (motor anterior) se cuenta como reintentable.
   */
  static delegationRetry(events: OrderEvent[]): { retryable: number; blocked: string[] } | null {
    const last = new Map<number, Record<string, unknown>>();
    for (const e of events) {
      const kind = String(e.kind || '');
      if (kind !== 'delegation_subtask_finished_v1' && kind !== 'delegation_audit_retry_v1') continue;
      const p = eventPayload(e);
      const child = Number(p.child_order_id);
      if (Number.isFinite(child) && child > 0) last.set(child, p);
    }
    if (!last.size) return null;
    let retryable = 0;
    const blocked: string[] = [];
    for (const p of last.values()) {
      if (p.unaudited !== true) continue;
      if (p.retryable === false) {
        const why = String(p.error ?? '').trim() || 'no se puede reintentar';
        blocked.push(`Subtarea ${String(p.index ?? '?')}: ${why}`);
      } else retryable++;
    }
    return { retryable, blocked };
  }

  /**
   * A7 (10-nov): la línea del grupo plegado de una orden anterior. Lo que
   * hizo («Ejecutó 3 tareas · escribió 2 archivos · 1 min»), no «Orden #N ·
   * Fallida · 0 tareas»: el número queda dentro y en el `title`.
   */
  private priorSummary(po: PriorOrder): string {
    if (po.eventsLoaded && po.events.length) {
      const a = act.construirActividad(po.events, { ahora: Date.now(), vivo: false });
      if (act.hayTrabajo(a)) return act.resumenTrabajo(a);
    }
    const parts: string[] = [];
    const n = po.plan?.tasks?.length ?? 0;
    if (po.planLoaded && n > 0) parts.push(`Plan de ${n} ${n === 1 ? 'tarea' : 'tareas'}`);
    const files = MissionControlPanel.priorFiles(po.events);
    if (files.length) {
      parts.push(`escribió ${files.length > 3 ? `${files.slice(0, 3).join(', ')} +${files.length - 3}` : files.join(', ')}`);
    }
    if (!parts.length) parts.push('Trabajo del agente');
    return parts.join(' · ');
  }

  private priorActivityMarkup(po: PriorOrder): string {
    if (!po.eventsLoaded) {
      return `<div class="subtle" data-prior-pending style="font-size:11px">${
        po.loading ? 'Cargando la actividad…' : 'La actividad se carga al desplegar este bloque.'
      }</div>`;
    }
    if (!po.events.length) return '';
    const a = act.construirActividad(po.events, { ahora: Date.now(), vivo: false });
    // Ya dentro del grupo plegable: las operaciones van directas, sin otro
    // desplegable anidado.
    if (!a.operaciones.length) return '';
    const ops = a.operaciones.slice(-MissionControlPanel.ACTIVITY_PAGE);
    const cards = ops
      .map((op) => {
        const salida = [op.stdout, op.stderr].filter(Boolean).join('\n');
        const abrir = op.familia === 'archivo' ? op.detalle : undefined;
        return cardMarkup(
          `${op.titulo}${op.eventos > 1 ? ` · ${op.eventos} eventos` : ''}`,
          [[op.detalle, salida].filter(Boolean).join('\n'), op.atribucion].filter(Boolean).join('\n'),
          MissionControlPanel.COLOR_ESTADO[op.estado],
          abrir,
          abrir ? artifactAction(po.events, abrir) : undefined
        );
      })
      .join('');
    return `<div class="col prior-activity" style="gap:8px">${cards}</div>`;
  }

  private priorCheckpointMarkup(po: PriorOrder): string {
    if (po.checkpointMsg) {
      return `<div class="card"><div class="card__subtitle">${esc(po.checkpointMsg)}</div></div>`;
    }
    if (!po.checkpoint) return '';
    const blocked = !this.canRestorePrior();
    const title = blocked
      ? 'Hay una orden activa; espera a que termine o cancélala antes de restaurar este punto de control.'
      : `Deshace los cambios que la orden #${po.orderId} hizo en los archivos`;
    return `<div class="card">
      <div class="row" style="justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
        <div class="col" style="gap:2px">
          <span class="card__title">Punto de control</span>
          <span class="subtle mono" style="font-size:11px">${esc(po.checkpoint.sha.slice(0, 10))}</span>
        </div>
        <button class="btn btn--danger" data-prior-revert="${po.orderId}" ${blocked ? 'disabled' : ''} title="${escapeAttribute(title)}">Revertir los archivos</button>
      </div>
    </div>`;
  }

  /**
   * B1d (11-nov): «Revertir» de una vuelta anterior de Directo, compacto y
   * bajo SU respuesta (como el de la vuelta en curso). Usa SU punto de
   * control: revertirla deja el proyecto como estaba antes de ESA vuelta.
   */
  private priorTurnCheckpointMarkup(po: PriorOrder): string {
    if (po.checkpointMsg) {
      return `<div class="turn-checkpoint subtle" role="status" style="font-size:11.5px;margin:-2px 0 4px 2px"><span>${esc(po.checkpointMsg)}</span></div>`;
    }
    if (!po.checkpoint) return '';
    const blocked = !this.canRestorePrior();
    const title = blocked
      ? 'Hay una orden activa; espera a que termine o cancélala antes de restaurar este punto de control.'
      : 'Deja el proyecto como estaba antes de esta vuelta: restaura lo modificado o borrado y borra lo creado después';
    return MissionControlPanel.turnCheckpointRow(
      po.checkpoint.sha,
      `<button class="btn btn--ghost btn--sm" data-prior-revert="${po.orderId}" ${blocked ? 'disabled' : ''} title="${escapeAttribute(title)}" style="color:var(--danger)">Revertir los archivos</button>`
    );
  }

  /** Fila compacta «Punto de control <sha> · Revertir los archivos» bajo una respuesta. */
  private static turnCheckpointRow(sha: string, button: string): string {
    return `<div class="turn-checkpoint row" style="gap:8px;align-items:center;flex-wrap:wrap;font-size:11.5px;margin:-2px 0 4px 2px">
      <span class="subtle">Punto de control</span>
      <span class="subtle mono" style="font-size:11px">${esc(sha.slice(0, 10))}</span>
      ${button}
    </div>`;
  }

  /**
   * B1d (11-nov): ¿la vuelta escribió en el proyecto? Misma fuente de verdad
   * que la línea «Archivos cambiados: …» que el motor pone bajo la respuesta
   * (`direct_mode.fileFacts`, escrituras reales, no el texto del modelo), más
   * lo que las subtareas delegadas integraron en la carpeta.
   * B1e (11-nov): y si la vuelta EJECUTÓ algún comando (`run_command`), que
   * pudo cambiar archivos aunque no haya escrituras directas. La fuente es el
   * evento del motor `native_tool_result_v1` de esa orden con su `exit_code`
   * (el comando llegó a correr); un comando rechazado trae `error` y no cuenta.
   */
  private static turnWrote(turns: ThreadTurn[], events: OrderEvent[]): boolean {
    return (
      turns.some((t) => t.role === 'assistant' && /^Archivos cambiados: /.test(splitFacts(t.text).facts ?? '')) ||
      events.some((e) => e.kind === 'delegation_finished_v1' && Number(eventPayload(e).integrated) > 0) ||
      events.some((e) => {
        if (e.kind !== 'native_tool_result_v1') return false;
        const p = eventPayload(e);
        return p.tool_name === 'run_command' && p.error === undefined && ('exit_code' in p || p.timed_out === true);
      })
    );
  }

  /** ¿Se ofrece el punto de control de la orden o vuelta en curso? */
  private currentCheckpointOffered(): boolean {
    return !this.turnCheckpoint || MissionControlPanel.turnWrote(this.turns.slice(this.priorTurnCount), this.events);
  }

  /**
   * B1d (11-nov): punto de control de la vuelta en curso de Directo, compacto
   * bajo la respuesta. Sin git solo se dice si la vuelta llegó a escribir.
   */
  private turnCheckpointMarkup(): string {
    if (!this.currentCheckpointOffered()) return '';
    if (this.checkpointMsg) {
      return `<div class="turn-checkpoint subtle" role="status" style="font-size:11.5px;margin:-2px 0 4px 2px"><span>${esc(this.checkpointMsg)}</span></div>`;
    }
    if (!this.checkpoint) {
      const noGit = /repositorio|not a git|no es un repo/i.test(this.checkpointError || '');
      const why = noGit
        ? 'La carpeta no es un repositorio git: los cambios de esta vuelta no se pueden revertir desde aquí.'
        : this.checkpointError || 'No se pudo tomar una foto del proyecto antes de esta vuelta.';
      return `<div class="turn-checkpoint row" role="note" style="gap:8px;align-items:center;flex-wrap:wrap;font-size:11.5px;margin:-2px 0 4px 2px">
        <span style="color:var(--warning);display:inline-flex">${icons.alert(12)}</span>
        <span style="font-weight:550">Sin punto de control</span>
        <span class="subtle">${esc(why)}</span>
        ${noGit ? '<button class="btn btn--sm" id="btn-git-init" title="Crea un repositorio git local (git init) en la carpeta de trabajo; no sube nada">Iniciar git aquí</button>' : ''}
      </div>`;
    }
    return MissionControlPanel.turnCheckpointRow(
      this.checkpoint.sha,
      `<button class="btn btn--ghost btn--sm" id="btn-revert" title="Deja el proyecto como estaba antes de esta vuelta: restaura lo modificado o borrado y borra lo creado después" style="color:var(--danger)">Revertir los archivos</button>`
    );
  }

  /**
   * A7 (10-nov): una orden anterior con trabajo se lee como conversación:
   * el mensaje del usuario, UNA línea plegable con lo que hizo (plan, tareas,
   * operaciones y punto de control dentro) y la respuesta. Ya no es una
   * tarjeta «Orden #N · Fallida · 0 tareas» que envuelve todo el turno.
   */
  private priorBlockMarkup(po: PriorOrder): string {
    const tasks = po.plan?.tasks ?? [];
    const saved = this.events;
    this.events = po.events;
    let plan = '';
    try {
      plan = tasks.length ? this.planTasksMarkup(tasks) : '';
    } finally {
      this.events = saved;
    }
    const estado = po.status && po.status !== 'done' ? statusLabel(po.status) : '';
    const group = `<details class="prior-order work-group" data-prior-order="${po.orderId}" ${po.open ? 'open' : ''}
        style="border:1px solid var(--border-subtle);border-radius:8px" title="Orden #${po.orderId}">
      <summary class="row" style="gap:10px;align-items:center;cursor:pointer;padding:7px 10px;list-style:none;user-select:none"
               aria-label="Lo que hizo el agente (orden #${po.orderId})">
        ${icons.chevronDown(13)}
        <span class="prior-order__title work-group__summary" style="font-size:12.5px;font-weight:550;color:var(--fg)">${esc(this.priorSummary(po))}</span>
        ${estado ? `<span class="badge">${esc(estado)}</span>` : ''}
      </summary>
      <div class="col" style="gap:10px;padding:4px 10px 10px">
        <div class="subtle" style="font-size:11px">Orden #${po.orderId}</div>
        ${po.planError ? `<div class="card"><div class="card__subtitle">No se pudo leer el plan de la orden #${po.orderId}: ${esc(po.planError)}. Despliega el bloque para reintentar.</div></div>` : ''}
        ${tasks.length && po.plan?.understanding ? `<div class="card"><div class="section-label" style="margin-bottom:6px">Entendimiento</div>${this.clampedMarkup(po.plan.understanding)}</div>` : ''}
        ${plan}
        ${this.priorActivityMarkup(po)}
        ${po.turn ? '' : this.priorCheckpointMarkup(po)}
      </div>
    </details>`;
    return this.splitTurnsMarkup(po.turns, group, false) + (po.turn ? this.priorTurnCheckpointMarkup(po) : '');
  }

  private priorStatusOfPhase(): string {
    switch (this.phase) {
      case 'error':
        return /cancelad/i.test(this.errorText) ? 'cancelled' : 'failed';
      case 'awaiting-approval':
        return 'planned';
      case 'interrupted':
        return 'interrupted';
      case 'audit-unavailable':
        return 'audit_unavailable';
      default:
        return 'done';
    }
  }

  /**
   * Pasa la orden en curso (terminada o abandonada) a `priorOrders` ANTES de
   * que `submit`/`reset` limpien su estado. Nada se destruye: el plan, los
   * eventos, el punto de control y los turnos de texto se mudan al bloque.
   */
  private archiveCurrentOrder(): void {
    if (!this.orderId || this.phase === 'idle' || this.turns.length <= this.priorTurnCount) return;
    if (this.priorOrders.some((p) => p.orderId === this.orderId)) return;
    const turns = this.turns.slice(this.priorTurnCount).map((t) => ({ ...t }));
    const tasks = this.plan?.tasks?.length ?? 0;
    // B1d: la vuelta de Directo que no escribió nada no conserva su punto de
    // control (un «Hola» sigue siendo conversación, no un bloque de trabajo).
    // Un plan con tareas aprobado ya cambió a su propio punto de control
    // (approve pone turnCheckpoint a false).
    const turnCk = this.turnCheckpoint;
    const keepCheckpoint = !turnCk || MissionControlPanel.turnWrote(turns, this.events);
    const checkpoint = keepCheckpoint ? this.checkpoint : null;
    const checkpointMsg = keepCheckpoint ? this.checkpointMsg : '';
    const hasCheckpoint = !!(checkpoint || checkpointMsg);
    // A7 (10-nov): un turno sin tareas ni punto de control es conversación
    // aunque haya fallado: se queda como mensajes, no como tarjeta «Orden #N
    // · Fallida · 0 tareas». Su fallo se conserva como respuesta en línea.
    // Directo sin tareas pero con comandos o archivos escritos sigue teniendo
    // su grupo plegable («Ejecutó 1 comando · escribió 1 archivo»).
    const worked = act.hayTrabajo(act.construirActividad(this.events, { ahora: Date.now(), vivo: false }));
    const isChat = tasks === 0 && !hasCheckpoint && !worked;
    if (this.phase === 'error' && this.errorText && !turns.some((t) => t.role === 'assistant' && t.text.trim() === this.errorText.trim()))
      turns.push({ role: 'assistant', text: this.errorText, failed: true });
    this.priorOrders.push({
      orderId: this.orderId,
      status: this.priorStatusOfPhase(),
      kind: isChat ? 'chat' : 'work',
      turns,
      plan: isChat ? null : this.plan,
      events: isChat ? [] : MissionControlPanel.boundEvents(this.events),
      eventsLoaded: true,
      planLoaded: true,
      planError: '',
      loading: false,
      open: false,
      checkpoint,
      checkpointRoot: this.checkpointRoot,
      checkpointMsg,
      turn: turnCk,
    });
    this.priorTurnCount = this.turns.length;
    // La orden en curso pasa a ser la siguiente: nada de lo que se haga con
    // ella (cancelar, aprobar) puede apuntar a la que acaba de archivarse.
    this.orderId = 0;
    this.checkpoint = null;
    this.checkpointError = '';
    this.checkpointMsg = '';
    this.checkpointRoot = '';
    this.turnCheckpoint = false;
    this.checkpointAttempted = false;
    this.shipPrs = [];
    this.shipBusy = false;
    this.shipError = '';
    this.shipManual = null;
    this.releaseOldPriorEvents();
  }

  /** Cota de memoria: solo las más recientes conservan sus eventos; el resto, al desplegar. */
  private releaseOldPriorEvents(): void {
    const keepFrom = this.priorOrders.length - MissionControlPanel.PRIOR_EVENTS_KEEP;
    this.priorOrders.forEach((po, i) => {
      if (i < keepFrom && po.eventsLoaded && !po.open && po.kind === 'work') {
        po.events = [];
        po.eventsLoaded = false;
      }
    });
  }

  /** Trae el plan y/o los eventos de una orden anterior. Idempotente y con cota. */
  private async hydratePrior(po: PriorOrder, withEvents: boolean, render = true): Promise<void> {
    if (!this.core || po.loading) return;
    const needPlan = !po.planLoaded;
    const needEvents = withEvents && !po.eventsLoaded;
    if (!needPlan && !needEvents) return;
    po.loading = true;
    try {
      if (needPlan) {
        try {
          po.plan = (await this.core.getPlan(po.orderId)) as OrderPlan;
          po.planError = '';
          po.planLoaded = true;
          if (po.plan?.tasks?.length) {
            po.kind = 'work';
          } else {
            // A7 (10-nov): sin tareas es conversación, también si falló
            // (antes, todo lo que no terminó bien se pintaba como tarjeta
            // «Orden #N · Fallida · 0 tareas»). Solo en las órdenes recientes
            // —las que la cota deja cargar eventos— se mira si el agente
            // trabajó (Directo que ejecutó o escribió) para darle su grupo
            // plegable; las antiguas no piden sus eventos (r4 P1, cota).
            po.kind = 'chat';
            po.events = [];
            po.eventsLoaded = true;
            if (withEvents) {
              try {
                const evs = MissionControlPanel.boundEvents(await this.core.orderEvents(po.orderId, 0));
                if (act.hayTrabajo(act.construirActividad(evs, { ahora: Date.now(), vivo: false }))) {
                  po.kind = 'work';
                  po.events = evs;
                }
              } catch (e) {
                // No se sabe si trabajó: los mensajes siguen a la vista y el
                // fallo de lectura se dice en el hilo, no se oculta.
                po.eventsError = String(e);
              }
            }
            // El fallo de un turno conversacional se ve como respuesta en
            // línea, una sola vez (su texto es el «entendimiento» del plan).
            const reply = (po.plan?.understanding || '').trim();
            const failedOrder = /^(failed|6)$/i.test(String(po.status));
            if (failedOrder && reply && !po.turns.some((t) => t.role === 'assistant'))
              po.turns.push({ role: 'assistant', text: reply, failed: true });
            else if (failedOrder) {
              const lastAssistant = [...po.turns].reverse().find((t) => t.role === 'assistant');
              if (lastAssistant) lastAssistant.failed = true;
            }
          }
        } catch (e) {
          // r4 P2: «sin plan» no es «no se pudo leer». Ante un error NO se pasa
          // a charla ni se marca el plan como leído: se mantiene como bloque,
          // se muestra el fallo y queda pendiente de reintento (al desplegar).
          po.plan = null;
          po.planError = String(e);
          po.kind = 'work';
        }
      }
      // Una orden sin tareas ya trajo sus eventos al clasificarse (A7): no se piden dos veces.
      if (needEvents && po.kind === 'work' && !po.eventsLoaded) {
        try {
          po.events = MissionControlPanel.boundEvents(await this.core.orderEvents(po.orderId, 0));
        } catch {
          po.events = [];
        }
        po.eventsLoaded = true;
      }
    } finally {
      po.loading = false;
    }
    if (render && this.priorOrders.includes(po)) this.renderBody();
  }

  private canRestorePrior(): boolean {
    return !this.isBusy() && this.phase !== 'awaiting-approval';
  }

  /** «Revertir los archivos» de un bloque anterior: SU punto de control, no el de la orden en curso. */
  private async revertPrior(orderId: number): Promise<void> {
    const po = this.priorOrders.find((p) => p.orderId === orderId);
    if (!this.core || !po?.checkpoint || !this.canRestorePrior()) return;
    const checkpoint = po.checkpoint;
    const epoch = this.orderEpoch;
    // B1d (11-nov): una vuelta anterior de Directo se nombra por su mensaje;
    // revertirla deja el proyecto como estaba antes de ESA vuelta, también
    // sin lo que hicieron las vueltas posteriores.
    const asked = po.turns.find((t) => t.role === 'user')?.text.trim() ?? '';
    const accepted = await confirmModal(po.turn ? {
      title: 'Revertir los archivos de una vuelta anterior',
      paragraphs: [
        `Se restaurarán los archivos al punto de control ${checkpoint.sha}, tomado justo antes de la vuelta «${asked.length > 80 ? `${asked.slice(0, 80)}…` : asked}».`,
        'El proyecto vuelve a como estaba antes de ESA vuelta: se restauran los archivos modificados o borrados y se borran los creados después, incluidos los cambios de las vueltas y órdenes posteriores. Lo ignorado por .gitignore no se toca.',
      ],
      confirmLabel: 'Revertir los archivos',
      danger: true,
    } : {
      title: `Restaurar el punto de control de la orden #${po.orderId}`,
      paragraphs: [
        `Se restaurarán los archivos al punto de control ${checkpoint.sha}, anterior a la ejecución de la orden #${po.orderId}.`,
        'El proyecto vuelve a ese estado: se restauran los archivos modificados o borrados y se borran los creados después, incluidos los cambios posteriores de otras órdenes. Lo ignorado por .gitignore no se toca.',
      ],
      confirmLabel: 'Revertir los archivos',
      danger: true,
    });
    // El diálogo es asíncrono: otra entrada puede iniciar una orden o cambiar de hilo.
    if (!accepted || !this.canRestorePrior() || epoch !== this.orderEpoch || !this.priorOrders.includes(po)) return;
    try {
      const r = await this.core.restoreCheckpoint(checkpoint.sha, po.checkpointRoot);
      po.checkpointMsg = checkpointRestoreMessage(r);
      MissionControlPanel.announceFilesChanged();
    } catch (e) {
      po.checkpointMsg = `No se pudo revertir: ${String(e)}`;
    }
    this.renderBody();
  }

  private bindPrior(body: HTMLElement): void {
    body.querySelectorAll<HTMLDetailsElement>('details[data-prior-order]').forEach((det) => {
      const po = this.priorOrders.find((p) => p.orderId === Number(det.dataset.priorOrder));
      if (!po) return;
      det.addEventListener('toggle', () => {
        po.open = det.open;
        if (det.open && !po.eventsLoaded) void this.hydratePrior(po, true);
      });
    });
    body.querySelectorAll<HTMLElement>('[data-prior-revert]').forEach((b) =>
      b.addEventListener('click', () => void this.revertPrior(Number(b.dataset.priorRevert)))
    );
  }

  private renderRun(): string {
    const header = `
      <div class="row" style="justify-content:space-between">
        <div class="row" style="gap:8px">
          ${this.phase === 'planning' || this.phase === 'running' ? '<span class="spinner"></span>' : ''}
          <span style="font-weight:600"${this.orderId ? ` title="Orden #${this.orderId}"` : ''}>${esc(this.phaseLabel())}</span>
          ${
            // A7 (10-nov): la cabecera habla de la conversación. El número de
            // orden sigue en el `title` y dentro del grupo de trabajo
            // desplegado (lo usan la campana, el grafo y el registro).
            `<span class="badge">${this.turns.length} mensaje(s)</span>`
          }
          ${this.contextBadge()}
          ${this.orderPinBadge()}
        </div>
        <span class="subtle mono" id="mission-elapsed">${this.elapsed()}</span>
      </div>`;

    // A7 (10-nov): el plan, el entendimiento y lo hecho viajan en el grupo
    // plegable, entre el mensaje y la respuesta (ver renderActivity).
    const workGroup = (): string =>
      this.events.length || this.plan?.tasks?.length
        ? `<div class="col" style="gap:6px" id="mission-events">${this.renderActivity()}</div>`
        : '';

    if (this.phase === 'error') {
      // El fallo se lee como una respuesta en línea, una sola vez: si el
      // último turno ya lo dice, no se repite en una tarjeta aparte.
      const live = this.turns.slice(this.priorTurnCount);
      const last = live[live.length - 1];
      const already = !!last && last.role === 'assistant' && last.text.trim() === this.errorText.trim();
      return (
        header +
        // El hilo NO se borra al fallar. Antes desaparecía la conversación
        // entera y "Volver al inicio" te dejaba en una pantalla vacía, como si
        // hubieras empezado de cero: un error no debe costarte el contexto.
        // El plan y las acciones TAMPOCO se borran: van en el grupo plegable.
        this.conversationMarkup(workGroup()) +
        (already
          ? ''
          : `<div class="chat-thread"><div class="chat-turn chat-turn--assistant"><div class="chat-bubble chat-bubble--failed">${esc(this.errorText)}</div></div></div>`) +
        // Justo cuando algo ha salido mal es cuando más falta hace poder volver
        // atrás, así que el punto de control se ofrece también aquí.
        // B1d: en una vuelta de Directo, solo si llegó a escribir archivos.
        (this.turnCheckpoint ? this.turnCheckpointMarkup() : this.checkpointMarkup()) +
        `<div class="row" style="gap:8px"><button class="btn" id="btn-mission-retry" title="Vuelve a intentar la orden completa">Reintentar</button>
         <button class="btn btn--ghost" id="btn-mission-reset" title="Vuelve al chat y sigue conversando">Seguir conversando</button></div>`
      );
    }

    if (this.phase === 'interrupted') {
      return (
        header +
        // La orden conserva su actividad y su plan parcial: la interrupción
        // no borra lo que el agente ya había hecho ni lo esconde.
        this.conversationMarkup(workGroup()) +
        `<div class="card" style="border-color:var(--warning)">
           <b>Orden interrumpida.</b> La aplicación se cerró mientras el agente
           trabajaba en ella. No se reanuda sola porque relanzarla gasta cuota
           de proveedor — es decisión tuya. Al reanudar, las tareas ya
           completadas se conservan y la que quedó a medias se re-ejecuta
           entera (no hay continuidad interna que fingir).
         </div>
         <button class="btn" id="btn-order-resume" title="Continúa la orden interrumpida desde el último punto guardado">Reanudar orden</button>
         <button class="btn btn--ghost" id="btn-mission-reset" title="Vuelve al chat y sigue conversando">Seguir conversando</button>`
      );
    }

    if (this.phase === 'audit-unavailable') {
      // P1-4: una vuelta que delegó y cuyas hijas sin auditar ya no tienen
      // copia de trabajo no ofrece «Reintentar»: no queda nada que auditar.
      const deleg = MissionControlPanel.delegationRetry(this.events);
      if (deleg && deleg.retryable === 0 && deleg.blocked.length) {
        return (
          header +
          this.conversationMarkup(workGroup()) +
          `<div class="card" style="border-color:var(--warning)" id="audit-not-retryable">
             <b>Sin auditar.</b> Ninguna subtarea pendiente se puede volver a
             auditar: su copia de trabajo ya no existe. Pide de nuevo la
             subtarea si sigues necesitando ese trabajo.
             <ul style="margin:6px 0 0 18px">${deleg.blocked.map((b) => `<li>${esc(b)}</li>`).join('')}</ul>
           </div>
           <button class="btn btn--ghost" id="btn-mission-reset" title="Vuelve al chat y sigue conversando">Seguir conversando</button>`
        );
      }
      return (
        header +
        // El trabajo ejecutado y los gates que sí corrieron se conservan a la
        // vista — la falta de auditoría no esconde lo que sí se hizo.
        this.conversationMarkup(workGroup()) +
        `<div class="card" style="border-color:var(--warning)">
           <b>Sin auditar.</b> La ejecución terminó y los resultados se
           conservan, pero el auditor no produjo un veredicto usable
           (proveedor agotado o respuesta irreconocible). No es un fallo del
           entregable ni una aprobación: la entrega como PR sigue bloqueada
           hasta que una auditoría válida confirme el resultado. Reintentarla
           reejecuta solo las tareas de auditoría pendientes — lo ya hecho no
           se repite — y gasta cuota de proveedor: es decisión tuya.
         </div>
         <button class="btn" id="btn-audit-retry" title="Reejecuta solo las auditorías que quedaron sin veredicto">Reintentar auditoría</button>
         <button class="btn btn--ghost" id="btn-mission-reset" title="Vuelve al chat y sigue conversando">Seguir conversando</button>`
      );
    }

    if (this.phase === 'planning') {
      // Si ya hay conversación, se mantiene a la vista y el esqueleto va DEBAJO,
      // como una burbuja del agente que aún no ha llegado. Antes se borraba
      // todo el hilo en cada envío y volvía a aparecer al responder: parecía
      // que la conversación se perdía.
      if (this.turns.length) {
        // USUARIO-NUEVO B (10-nov): en Directo/DevAgents el modelo TRABAJA
        // durante esta fase (y en DevAgents delega). El grupo de la vuelta se
        // pinta en vivo entre el mensaje y la respuesta pendiente: paintEvents
        // lo rellena con cada evento; sin trabajo (un «Hola»), queda vacío.
        const live = this.directMode
          ? `<div class="col" style="gap:6px" id="mission-events">${this.events.length ? this.renderActivity() : ''}</div>`
          : '';
        return (
          header +
          this.threadMarkup() +
          live +
          `<div class="chat-turn chat-turn--assistant">
             <div class="chat-bubble col" style="gap:8px;min-width:200px">
               <div class="shimmer" style="height:10px;border-radius:4px;width:80%"></div>
               <div class="shimmer" style="height:10px;border-radius:4px;width:55%"></div>
               <div id="planning-note" class="subtle" style="font-size:11px">${esc(this.planningNote())}</div>
             </div>
           </div>`
        );
      }
      return (
        header +
        `<div class="card col" style="gap:8px">
           <div class="shimmer" style="height:12px;border-radius:4px;width:70%"></div>
           <div class="shimmer" style="height:12px;border-radius:4px;width:45%"></div>
           <div class="shimmer" style="height:12px;border-radius:4px;width:60%"></div>
           <div id="planning-note" class="subtle" style="font-size:11px">${esc(this.planningNote())}</div>
         </div>`
      );
    }

    const plan = this.plan;
    let out = header;

    // Charla: se pinta el hilo entero, no un "entendimiento" suelto. El
    // compositor sigue abajo, así que responder continúa la misma conversación.
    if (this.phase === 'chat') {
      out += this.autoCompactBannerMarkup();
      // A7 (10-nov): lo que el agente hizo va ENTRE el mensaje y la
      // respuesta; si solo conversó, renderActivity no pinta nada.
      // Una sesión histórica puede no tener mensajes persistidos y sí eventos
      // con artefactos; ocultarlos haría que una orden ejecutable pareciera vacía.
      out += this.conversationMarkup(workGroup());
      // USUARIO-NUEVO B / B1d (11-nov): si esta vuelta escribió archivos (la
      // línea «Archivos cambiados» del motor) o integró subtareas delegadas,
      // el punto de control tomado al enviar queda bajo la respuesta con
      // «Revertir los archivos», compacto. Sin escrituras no se pinta nada.
      if (this.turnCheckpoint) out += this.turnCheckpointMarkup();
      // "Nueva conversación" vive en la barra de pestañas y en la lista de
      // sesiones. Aquí estaba por tercera vez.
      // El texto de ayuda ("Sigue escribiendo abajo para continuar…") se retiró
      // a petición del usuario: repetía en cada respuesta algo que se aprende
      // la primera vez, y ensuciaba el hilo.
      if (this.estimatedTokens() > 16000 && !this.autoCompactBannerMarkup()) {
        out += `<div class="row" style="gap:8px">
          <button class="btn" id="btn-compact" title="Resume el historial de la conversación para liberar contexto del modelo">Compactar conversación</button>
        </div>`;
      }
      return out;
    }

    // A7 (10-nov): ejecutando, terminada o en elección de best-of-N, la orden
    // se lee como conversación: mensaje, grupo plegable con el plan, sus
    // tareas, el grafo y lo hecho, y la respuesta. El punto de control y el
    // envío a GitHub quedan a la vista (son acciones), no plegados.
    if (this.phase === 'running' || this.phase === 'done' || this.phase === 'best-of-n') {
      out += this.autoCompactBannerMarkup();
      // En best-of-n los eventos best_of_n_* (composición, candidata que
      // termina, ranking) son la única traza del torneo — van en el grupo.
      out += this.conversationMarkup(`<div class="col" style="gap:6px" id="mission-events">${this.renderActivity()}</div>`);
      if (this.phase === 'best-of-n') out += this.bestOfNMarkup();
      if (this.phase === 'done') {
        out += this.checkpointMarkup();
        out += this.shipMarkup();
        out += `<button class="btn" id="btn-mission-reset" title="Empezar una orden nueva">Nueva orden</button>`;
      }
      return out;
    }

    // El hilo se pintaba SOLO en las fases 'chat', 'planning' y 'error'. En
    // cuanto el planner devolvía tareas, la conversación entera desaparecía y
    // la pantalla se quedaba en "Entendimiento + Plan + Aprobar", como si se
    // hubiera empezado de cero. Aprobar y ejecutar son parte de la misma
    // conversación, así que el hilo se queda arriba en todas las fases.
    out += this.autoCompactBannerMarkup();
    if (this.turns.length) out += this.threadMarkup();

    if (plan?.understanding) {
      out += `<div class="card"><div class="section-label" style="margin-bottom:6px">Entendimiento</div>
              ${this.clampedMarkup(plan.understanding)}</div>`;
    }

    if (this.phase === 'clarifying' && plan?.questions?.length) {
      out += `<div class="card col" style="gap:12px">
        <div class="section-label">El agente necesita aclarar ${plan.questions.length} punto(s)</div>
        ${plan.questions
          .map(
            (q) => `<div class="field">
              <span class="field__label">${esc(q.text)}</span>
              ${
                q.options?.length
                  ? `<select class="select" data-answer="${escapeAttribute(q.id)}">${q.options
                      .map((o) => `<option value="${escapeAttribute(o)}">${esc(o)}</option>`)
                      .join('')}</select>`
                  : `<input class="input" data-answer="${escapeAttribute(q.id)}" placeholder="Tu respuesta" />`
              }
            </div>`
          )
          .join('')}
        <button class="btn btn--primary" id="btn-send-answers" title="Envía las respuestas para que el planificador continúe">Enviar respuestas</button>
        <button class="btn" id="btn-discard" title="Cancela esta orden sin ejecutar el plan">Cancelar</button>
      </div>`;
      return out;
    }

    if (plan?.tasks?.length) {
      out += this.planTasksMarkup(plan.tasks);
    }

    if (this.phase === 'awaiting-approval') {
      out += `${plan?.wait_for_plan_approval ? '<div class="card" role="status">Modo Plan · esperando tu aprobación. No se ha ejecutado ninguna tarea.</div>' : ''}<div class="row" style="gap:8px">
             <button class="btn btn--primary" id="btn-approve" title="Aprueba el plan y empieza la ejecución de las tareas">${icons.play(13)} Aprobar y ejecutar</button>
             <button class="btn" id="btn-discard" title="Cancela esta orden sin ejecutar el plan">Cancelar</button>
           </div>
           <div class="card col" style="gap:8px;margin-top:8px">
             <label for="plan-change-request">Cambios al plan</label>
             <textarea class="textarea" id="plan-change-request" rows="2" placeholder="Describe qué debe cambiar el agente antes de ejecutar">${esc(this.planChangeDraft)}</textarea>
             <button class="btn" id="btn-plan-changes" ${this.planChangeDraft.trim() ? '' : 'disabled'}>Pedir cambios</button>
           </div>
           <details class="clamp-details" style="margin-top:8px">
             <summary>Editar el plan antes de aprobar</summary>
             <div class="card__subtitle" style="margin-top:6px">
               El motor guarda el plan editado como una revisión nueva (evento
               plan_edited) y ejecuta esa, no la original. Se edita en JSON
               porque es lo único que el motor sabe leer de vuelta.
             </div>
             <textarea class="textarea mono" id="plan-edit" rows="10"
               style="margin-top:6px;min-height:180px;font-size:11px"
               >${esc(this.planEditDraft ?? JSON.stringify(this.plan, null, 2))}</textarea>
             <div class="row" style="gap:8px;margin-top:8px;align-items:center">
               <button class="btn" id="btn-plan-save" title="Guarda el plan editado en el motor">Guardar plan</button>
               <span id="plan-msg" class="subtle" style="font-size:11px"></span>
             </div>
           </details>
           <details class="clamp-details" style="margin-top:8px">
             <summary>Declarar cómo se comprueba el resultado (opcional)</summary>
             <div class="card__subtitle" style="margin-top:6px">
               Si lo declaras, la orden no cierra en «done» hasta que la verificación
               semántica lo confirme sobre los archivos reales. Array JSON de
               aserciones: <span class="mono">file_exists</span>,
               <span class="mono">file_contains</span>,
               <span class="mono">file_not_contains</span> y
               <span class="mono">output_contains</span>.
             </div>
             <textarea class="textarea mono" id="order-expected" rows="3"
               placeholder='[{"kind":"file_exists","path":"index.html"},{"kind":"file_contains","path":"index.html","needle":"<title>"}]'
               style="margin-top:6px;min-height:60px;font-size:11px">${esc(this.expectedDraft)}</textarea>
           </details>`;
    }

    // 'running', 'done' y 'best-of-n' salen antes por su rama (A7). El chat
    // muestra ACCIONES, no la corriente cruda del motor: la traza sigue en
    // «Salida del motor» (panel inferior), que es donde se diagnostica.
    return out;
  }

  /**
   * Pinta la corriente de eventos plegando el razonamiento.
   *
   * El motor emite `reasoning_delta` desde hace tiempo (`emitReasoningDelta` en
   * live_worker.zig, con la traza separada de la respuesta real), pero aquí se
   * mostraba como una línea de JSON crudo más entre las demás. Los deltas
   * consecutivos se juntan en un único bloque desplegable, colapsado por
   * defecto: el razonamiento se consulta, no se lee de corrido.
   */
  /**
   * Tarjeta del punto de control. Se muestra al terminar la orden, bien o mal.
   *
   * Es deliberadamente explícita sobre lo que NO cubre: `git stash create` solo
   * fotografía lo que git ya sigue, así que los archivos nuevos que haya creado
   * el agente sobreviven a la reversión. Prometer un "deshacer" total y que
   * luego quede basura suelta sería peor que no ofrecerlo.
   */
  private checkpointMarkup(): string {
    if (this.checkpointMsg) {
      return `<div class="card"><div class="card__subtitle">${esc(this.checkpointMsg)}</div></div>`;
    }
    if (!this.checkpoint && !this.checkpointAttempted) return '';
    if (!this.checkpoint) {
      const why = this.checkpointError
        ? esc(this.checkpointError)
        : 'No se pudo tomar una foto del proyecto antes de ejecutar.';
      return `<div class="card">
        <div class="row" style="gap:6px;align-items:center">
          <span style="color:var(--warning)">${icons.alert(14)}</span>
          <span class="card__title">Sin punto de control</span>
        </div>
        <div class="card__subtitle" style="margin-top:6px">${why}</div>
        <div class="card__subtitle" style="margin-top:4px">
          Los puntos de control usan git: necesitan que la carpeta de trabajo sea un repositorio.
        </div>
        ${/repositorio|not a git|no es un repo/i.test(this.checkpointError || '')
          ? `<div class="row" style="margin-top:8px"><button class="btn btn--sm" id="btn-git-init" title="Crea un repositorio git local (git init) en la carpeta de trabajo; no sube nada">Iniciar git aquí</button></div>`
          : ''}
      </div>`;
    }
    return `<div class="card">
      <div class="row" style="justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
        <div class="col" style="gap:2px">
          <span class="card__title">Punto de control</span>
          <span class="subtle mono" style="font-size:11px">${esc(this.checkpoint.sha.slice(0, 10))}</span>
        </div>
        <button class="btn btn--danger" id="btn-revert" title="Deja el proyecto como estaba antes de esta orden: restaura lo modificado o borrado y borra lo creado">Revertir los archivos</button>
      </div>
    </div>`;
  }

  // --- E5.18: tarjeta comparativa Best-of-N ----------------------------------
  //
  // La orden despachó N órdenes hijas (una por miembro del enjambre, cada una
  // en su worktree `orden-<id>-m<k>`). El motor las rankea de forma
  // determinista (gates → pruebas → veredicto → coste → tiempo) pero NO elige:
  // un empate total queda con el mismo rank y la decisión es siempre humana.
  // «Elegir este» dispara la fusión real en el motor (applyWinner sobre el
  // worktree de la orden + archivo de las perdedoras).

  private bonData: BestOfNCard | null = null;
  private bonBusy = false;
  private bonError = '';
  private bonFilesOpen: number | null = null;
  private bonDiffHtml: string | null = null;
  private bonDiffTitle = '';

  private async loadBestOfN(): Promise<void> {
    if (!this.core || !this.orderId) return;
    try {
      this.bonData = await this.core.bestOfNCandidates(this.orderId);
      this.bonError = '';
    } catch (e) {
      this.bonError = String(e);
    }
    if (this.phase === 'best-of-n') this.renderBody();
  }

  private async chooseBonCandidate(candidateId: number): Promise<void> {
    if (!this.core || this.bonBusy || !this.orderId) return;
    this.bonBusy = true;
    this.bonError = '';
    this.renderBody();
    const orderId = this.orderId;
    try {
      await this.core.bestOfNChoose(orderId, candidateId);
      if (this.orderId !== orderId) return;
      const resumen = this.agentSummary();
      if (resumen) this.turns.push({ role: 'assistant', text: resumen });
      this.streamText = '';
      this.toggleCancel(false);
      this.setPhase('done');
    } catch (e) {
      this.bonError = `No se pudo aplicar la candidata: ${String(e)}`;
      this.renderBody();
    } finally {
      this.bonBusy = false;
    }
  }

  /** Diff candidata vs worktree de la orden — solo lectura (diff_viewer). */
  private async showBonDiff(candidateId: number, path: string): Promise<void> {
    const c = this.bonData?.candidates.find((x) => x.id === candidateId);
    const base = this.bonData?.parent_worktree;
    if (!c || !c.worktree || !base || !this.core) {
      this.bonError = 'No hay worktrees para comparar (la candidata puede estar archivada).';
      this.renderBody();
      return;
    }
    const join = (root: string, rel: string) => `${root.replace(/[\\/]+$/, '')}/${rel}`;
    // La candidata escribe bajo `orden-<hija>` y la padre lee `orden-<padre>`
    // (mismo reanclaje que applyWinner al fusionar): la comparación mira el
    // archivo que EXISTIRÍA en la orden tras elegir esta candidata.
    const childPrefix = c.child_order_id ? `orden-${c.child_order_id}/` : null;
    const parentRel =
      childPrefix && this.bonData && path.startsWith(childPrefix)
        ? `orden-${this.bonData.order_id}/${path.slice(childPrefix.length)}`
        : path;
    this.bonDiffTitle = `${parentRel} — orden vs candidata m${c.member_idx}`;
    this.bonDiffHtml = '<div class="row" style="gap:8px"><span class="spinner"></span><span class="subtle">Calculando diferencias…</span></div>';
    this.renderBody();
    try {
      const origDoc = await this.core.openDoc(join(base, parentRel)).catch(() => null);
      const candDoc = await this.core.openDoc(join(c.worktree, path)).catch(() => null);
      this.bonDiffHtml = previewHtml(origDoc?.content ?? '', candDoc?.content ?? '');
    } catch (e) {
      this.bonDiffHtml = `<div class="card__subtitle" style="color:var(--danger)">${esc(String(e))}</div>`;
    }
    if (this.phase === 'best-of-n') this.renderBody();
  }

  private bonFilesMarkup(c: BestOfNCandidate): string {
    if (!c.files.length && !c.deleted_files.length) {
      return '<span class="subtle" style="font-size:11px">La candidata no dejó archivos distintos, o su worktree no es git (diff no disponible).</span>';
    }
    const mk = (p: string, del: boolean) =>
      `<button class="btn btn--sm bon-file mono" data-cand="${escapeAttribute(c.id)}" data-path="${escapeAttribute(p)}" style="font-size:11px"
        title="Ver el diff de ${escapeAttribute(p)} contra el worktree de la orden">${del ? '− ' : ''}${esc(p)}</button>`;
    return `<div class="row" style="flex-wrap:wrap;gap:4px">
      ${c.files.map((p) => mk(p, false)).join('')}${c.deleted_files.map((p) => mk(p, true)).join('')}
    </div>`;
  }

  private bonRowMarkup(c: BestOfNCandidate): string {
    const rankBadge =
      c.rank === 1
        ? '<span class="badge badge--success">rank 1</span>'
        : c.rank
          ? `<span class="badge">rank ${esc(c.rank)}</span>`
          : '<span class="badge">sin rank</span>';
    const chosenBadge = c.chosen ? '<span class="badge badge--success">elegida</span>' : '';
    const verdictCls =
      c.audit_verdict === 'pass' ? 'badge--success' : c.audit_verdict === 'fail' ? 'badge--danger' : '';
    const veredicto =
      c.audit_verdict && c.audit_verdict !== 'none'
        ? `<span class="badge ${verdictCls}">${esc(c.audit_verdict)}</span>`
        : '<span class="subtle">sin veredicto</span>';
    const coste = c.cost_tokens === null ? 'coste sin medir' : `${c.cost_tokens} tokens`;
    const segundos = Math.round(Number(c.elapsed_ms) / 1000);
    const filesBtn =
      c.files.length || c.deleted_files.length
        ? `<button class="btn btn--sm bon-files" data-cand="${escapeAttribute(c.id)}"
             title="Lista los archivos que esta candidata dejó distintos en su worktree">
             ${c.files.length + c.deleted_files.length} archivo(s)</button>`
        : '<span class="subtle" style="font-size:11px">sin diff</span>';
    return `<div class="card" style="padding:10px 12px">
      <div class="row" style="justify-content:space-between;gap:8px;flex-wrap:wrap">
        <div class="col" style="gap:2px">
          <span class="card__title" style="font-size:13px">m${esc(c.member_idx)} · ${esc(c.provider)} / ${esc(c.model)}</span>
          <span class="subtle" style="font-size:11px">
            ${rankBadge} ${chosenBadge} estado ${esc(c.status)} ·
            gates ${esc(c.gates_pass)}✓/${esc(c.gates_fail)}✗ ·
            pruebas ${esc(c.tests_pass)}✓/${esc(c.tests_fail)}✗ ·
            auditoría ${veredicto} · ${esc(coste)} · ${segundos}s
          </span>
        </div>
        <div class="row" style="gap:6px">
          ${filesBtn}
          <button class="btn btn--primary btn--sm bon-choose" data-cand="${escapeAttribute(c.id)}" ${this.bonBusy ? 'disabled' : ''}
            title="Aplica los cambios de esta candidata al worktree de la orden y archiva las demás">${icons.check(13)} Elegir este</button>
        </div>
      </div>
      <div id="bon-files-${escapeAttribute(c.id)}" style="display:${this.bonFilesOpen === c.id ? 'block' : 'none'};margin-top:8px">
        ${this.bonFilesMarkup(c)}
      </div>
    </div>`;
  }

  private bestOfNMarkup(): string {
    const d = this.bonData;
    if (!d) {
      return `<div class="card"><div class="row" style="gap:8px"><span class="spinner"></span>
        <span class="subtle">Cargando candidatas…</span></div></div>`;
    }
    const cands = [...d.candidates].sort((a, b) => (a.rank ?? 99) - (b.rank ?? 99) || a.member_idx - b.member_idx);
    const tied = cands.filter((c) => c.rank === 1).length > 1;
    const err = this.bonError
      ? `<div class="banner banner--warning"><span>${icons.alert(14)} ${esc(this.bonError)}</span></div>`
      : '';
    const diffBlock = this.bonDiffHtml
      ? `<div class="card" style="margin-top:4px">
           <div class="row" style="justify-content:space-between">
             <span class="mono subtle" style="font-size:11px">${esc(this.bonDiffTitle)}</span>
             <button class="btn btn--sm" id="bon-diff-close">Cerrar diff</button>
           </div>
           <div style="margin-top:8px">${this.bonDiffHtml}</div>
         </div>`
      : '';
    return `<div class="card" id="bon-card">
      <div class="col" style="gap:4px">
        <span class="card__title">Best-of-N · ${d.candidates.length} candidatas ejecutadas</span>
        <span class="card__subtitle">
          Cada una corrió en su propio worktree con su modelo. El ranking es determinista
          (gates → pruebas → veredicto → coste → tiempo);${tied ? ' <b>hay empate total — la elección es tuya</b>.' : ' la elección final es tuya.'}
        </span>
      </div>
      ${err}
      <div class="col" style="gap:8px;margin-top:6px">${cands.map((c) => this.bonRowMarkup(c)).join('')}</div>
      ${diffBlock}
    </div>`;
  }

  /** Texto que el modelo lleva escrito en la respuesta en curso. */
  private streamText = '';

  /**
   * Frase con la que se cierra la orden en el hilo.
   *
   * Se toman los `agent_message` del motor, que es lo que él considera su
   * mensaje al usuario. Si no hubo ninguno se compone uno con el recuento de
   * `order_done`: es preferible a dejar la conversación sin cierre, porque
   * entonces parece que la orden se quedó a medias.
   */
  private agentSummary(): string {
    const mensajes: string[] = [];
    let hecho: { completed: number; failed: number } | null = null;
    const archivos: string[] = [];

    for (const e of this.events) {
      const p = eventPayload(e);
      const kind = String(e.kind || '');
      if (kind === 'agent_message') {
        // `text` puede venir como array de bytes cuando la salida de consola
        // no era UTF-8 limpio — decodificar, no imprimir la ensalada de números.
        const t = act.textoDeBytes(p.text).trim();
        if (t) mensajes.push(t);
      } else if (kind === 'order_done') {
        hecho = { completed: Number(p.completed ?? 0), failed: Number(p.failed ?? 0) };
      } else if (kind === 'file_written') {
        const f = String(p.file_path ?? '');
        if (f) archivos.push(basename(f));
      }
    }

    const partes: string[] = [];
    if (mensajes.length) partes.push(mensajes.join('\n\n'));
    if (hecho) {
      // (tanda 1, visto en vivo): una madre que solo delega cierra
      // con 0 tareas propias; «Listo: 0 tarea(s) completada(s)» contradecía
      // la subtarea que acababa de integrar. Sin tareas propias no se cuenta.
      const n = (k: number, una: string, varias: string) => `${k} ${k === 1 ? una : varias}`;
      const cuenta = hecho.completed || hecho.failed
        ? `Listo: ${n(hecho.completed, 'tarea completada', 'tareas completadas')}` +
          (hecho.failed ? `, ${n(hecho.failed, 'fallida', 'fallidas')}` : '')
        : 'Listo';
      partes.push(cuenta + (archivos.length ? `. Archivos: ${[...new Set(archivos)].join(', ')}` : '.'));
    }
    return partes.join('\n\n').trim();
  }

  /**
   * Acumula los `content_delta` y los manda a "Salida del motor".
   *
   * Ya NO se pintan en el chat. Estos deltas no son "la respuesta": llevan
   * mezclada la salida de cada llamada interna del motor —el selector de
   * herramientas el primero—, y el usuario acababa viendo un bloque
   * `[{"task_id":"t1","skills":[],"mcps":[]…}]` donde esperaba una frase. La
   * corriente sigue estando entera, pero en el panel inferior, que es donde se
   * diagnostica. En el chat manda `agent_message`, que es lo que el motor
   * considera su mensaje al usuario.
   */
  private absorbStream(events: OrderEvent[]): void {
    let grew = false;
    for (const e of events) {
      if (String(e.kind || '') !== 'content_delta') continue;
      const p = eventPayload(e);
      const chunk = String(p.content ?? p.delta ?? p.text ?? '');
      if (chunk) {
        this.streamText += chunk;
        grew = true;
      }
    }
    // el stream es un string que solo crece; una orden larga (varias
    // por MCP son miles de deltas) inflaba el heap del renderer hasta que
    // WebView2 moría y la ventana quedaba en blanco puro. Se conserva la
    // cola — la traza completa sigue en runtime.db, que es la fuente.
    if (this.streamText.length > MissionControlPanel.STREAM_TEXT_CAP) {
      this.streamText =
        '[… inicio de la corriente recortado …]\n' +
        this.streamText.slice(-MissionControlPanel.STREAM_TEXT_CAP);
    }
    if (!grew) return;
    this.publishEngineOutput();
  }

  /**
 * cotas sobre los buffers de eventos en memoria. Los kinds de ráfaga
   * (deltas, salidas de worker) llegan por miles por orden y solo alimentan
   * filas PLEGADAS — retenerlos todos junto a `streamText` agotaba el heap
   * del renderer y la ventana quedaba blanca hasta reiniciar. Los hechos
   * (file_written, task_*, errores, approvals) son pocos y se conservan
   * siempre; la ráfaga se corta a la cola más reciente.
   */
  private static readonly STREAM_KINDS = new Set([
    'content_delta',
    'reasoning_delta',
    'worker_output',
    'subagent_stream_chunk',
  ]);
  private static readonly STREAM_KEEP = 1500;
  private static readonly EVENT_CAP = 6000;
  private static readonly STREAM_TEXT_CAP = 192 * 1024;

  /**
 * 11-nov (propietario): la esquina avisa del ESTADO de modelos y proveedores, no
   * de cada orden. Un modelo que no respondió levanta un aviso amarillo con
   * id por modelo (repetirlo en otra orden no crea otro) y se retira solo
   * cuando ese mismo modelo vuelve a responder. Solo eventos en vivo: abrir
   * una sesión antigua no resucita avisos viejos.
   */
  private watchModelHealth(nuevos: readonly OrderEvent[]): void {
    for (const ev of nuevos) {
      if (ev?.kind === 'directo_finished_v1') {
        const p = eventPayload(ev);
        if (p.cancelled === true) continue;
        const started = [...(this.events ?? [])].reverse().find(e => e.kind === 'directo_started_v1');
        const sp = started ? eventPayload(started) : {};
        const provider = String(p.provider || sp.provider || '');
        const model = String(p.model || sp.model || '');
        if (!provider || provider === 'auto') continue;
        const id = `model:${provider}|${model}`;
        if (p.ok === true) { clearAlert(id); continue; }
        const why = String(p.error_name || 'sin respuesta');
        raiseAlert({
          id,
          level: 'warn',
          title: `${this.shortModel(`${provider}|${model}`)} no responde`,
          body: `El proveedor devolvió «${why}». Las órdenes con este modelo pueden volver a fallar; elige otro o reintenta más tarde.`,
          startCollapsed: true,
          actions: [{ label: 'Elegir otro modelo', run: () => this.container.querySelector<HTMLElement>('#btn-model-picker')?.click() }],
        });
      } else if (ev?.kind === 'provider_exhausted') {
        raiseAlert({
          id: 'model:exhausted',
          level: 'warn',
          title: 'Ningún proveedor respondió',
          body: 'Se probaron todos los candidatos elegibles y ninguno contestó. Revisa claves, cupos o elige otro modelo.',
          startCollapsed: true,
          actions: [{ label: 'Elegir otro modelo', run: () => this.container.querySelector<HTMLElement>('#btn-model-picker')?.click() }],
        });
      } else if (ev?.kind === 'order_completed' || ev?.kind === 'order_done') {
        clearAlert('model:exhausted');
      }
    }
  }

  private trimEventBuffers(): void {
    this.events = MissionControlPanel.boundEvents(this.events);
  }

  /** Misma cota para el buffer vivo y para los eventos de órdenes anteriores. */
  private static boundEvents(list: OrderEvent[]): OrderEvent[] {
    if (list.length <= MissionControlPanel.EVENT_CAP) return list;
    let streamSeen = 0;
    const kept: OrderEvent[] = [];
    for (let i = list.length - 1; i >= 0; i--) {
      const e = list[i];
      if (MissionControlPanel.STREAM_KINDS.has(String(e?.kind ?? ''))) {
        if (streamSeen < MissionControlPanel.STREAM_KEEP) {
          kept.push(e);
          streamSeen++;
        }
        continue;
      }
      kept.push(e);
    }
    kept.reverse();
    // Cota dura: si aun así supera, caen los más antiguos sean del kind que
    // sean — mejor perder el arranque de la traza que la ventana entera.
    return kept.slice(-MissionControlPanel.EVENT_CAP);
  }

  /**
   * Manda al panel inferior TODO lo crudo: la corriente del modelo y la traza
   * de eventos con el razonamiento plegado. Es lo que se sacó del chat, así
   * que tiene que estar entero en algún sitio o se habría perdido.
   *
   * P3: también se sintetiza una lista corta de PROBLEMAS de esta orden. El
   * tab "Problemas" solo mostraba estado estático del motor (sin clave, sin
   * catálogo) y jamás lo que pasó en la orden que el usuario acaba de ver
   * fallar — "no sirvió: empty" no llegaba a ningún diagnóstico. Ahora sí.
   */
  private publishEngineOutput(): void {
    document.dispatchEvent(
      new CustomEvent('devagents:engine-output', {
        detail: { stream: this.streamText, traza: this.renderEventStream(), problemas: synthProblems(this.events) },
      })
    );
  }

  /**
   * Clave de localStorage para el estado de plegado de un grupo de tarjetas.
   * P4: el plegado PERSISTE por tipo de tarjeta — si el usuario despliega los
   * "cambios de proveedor" una vez, la preferencia queda para las siguientes
   * órdenes, no solo para esta.
   */
  private static collapseKey(kind: string): string {
    return `mc:collapse:${kind}`;
  }

  /**
   * Los eventos del motor convertidos en tarjetas de acción legibles, en
   * TRES niveles (P4, criterio del usuario 2026-08-07):
   *
   *   - Siempre visibles: plan, archivos escritos, procesos lanzados, resultado
   *     final, y el PRIMER error con su causa real.
   *   - Plegado con resumen de una línea: olas, tareas individuales, cambios de
   *     modelo, reintentos de proveedor — agrupados ("3 proveedores probados ·
   *     2 fallaron").
   *   - Solo depuración: `superagent_thinking` (el razonamiento), los
   *     `provider_fallback` uno a uno, muestras crudas.
   *
   * Dos reglas que no se negocian: el estado de plegado persiste por tipo de
   * tarjeta, y un error nunca se pliega solo — el ruido se esconde, el fallo no.
   */
  /**
   * CHAT-PD-1 — divulgación progresiva del turno.
   *
   * `null` significa «decide la fase»: abierto mientras trabaja, plegado al
   * terminar. En cuanto el usuario lo abre o lo cierra a mano, su decisión
   * manda y el plegado automático deja de tocarlo — inspeccionar el detalle y
   * que se te cierre solo al llegar el siguiente evento es exactamente el
   * comportamiento que había que quitar.
   */
  private activityOpen: boolean | null = null;
  /** Aprobaciones contestadas desde el hilo: en curso o con su error. */
  private threadApprovals = new Map<number, { busy: boolean; error: string }>();

  /** Filtro de la actividad desplegada. Vive en el panel, no en el DOM. */
  private activityFilter = '';

  /** Tope de operaciones pintadas de golpe; el resto queda a un clic. */
  private static readonly ACTIVITY_PAGE = 40;

  /** Cuántos bloqueos se enseñan fuera del bloque plegable. */
  private static readonly BLOQUEOS_A_LA_VISTA = 3;

  private activityShowAll = false;

  /** Estado del turno actual, calculado SIEMPRE desde los eventos reales. */
  private actividadActual(): act.ActividadTurno {
    const vivo = this.phase === 'running' || this.phase === 'planning';
    return act.construirActividad(this.events, { ahora: Date.now(), vivo });
  }

  private static readonly COLOR_ESTADO: Record<act.EstadoOperacion, string> = {
    ejecutando: 'var(--accent)',
    ok: 'var(--success)',
    fallo: 'var(--danger)',
    sin_ejecutar: 'var(--warning)',
    bloqueado: 'var(--warning)',
  };

  private static readonly ETIQUETA_ESTADO_TURNO: Record<act.EstadoTurno, string> = {
    ejecutando: 'En curso',
    completado: 'Completado',
    fallido: 'Fallido',
    cancelado: 'Cancelado',
    interrumpido: 'Interrumpido',
    sin_auditar: 'Sin auditar',
    esperando: 'Esperando',
  };

  private static readonly COLOR_ESTADO_TURNO: Record<act.EstadoTurno, string> = {
    ejecutando: 'var(--accent)',
    completado: 'var(--success)',
    fallido: 'var(--danger)',
    cancelado: 'var(--warning)',
    interrumpido: 'var(--warning)',
    sin_auditar: 'var(--warning)',
    esperando: 'var(--accent)',
  };

  /**
   * Lo que la conversación enseña de un turno: primero lo que reclama al
   * usuario, después el bloque plegable con TODO lo demás.
   *
   * La respuesta final NO se pinta aquí: va como turno del hilo, fuera del
   * bloque, para que se pueda leer sin desplegar nada.
   */
  /**
 * la orden como grafo encima de su actividad. Solo para órdenes
   * con tareas (Directo no reparte tareas y el grafo solo repetiría la
   * conversación). Apagado por defecto: entonces es una tira de puntos.
   */
  private renderActivity(): string {
    const graph = this.events.length ? buildOrderGraph(this.events, this.plan?.tasks ?? [], { orderId: this.orderId || 0 }) : null;
    const top = graph && graph.tasks.length ? String(graphEnabledNow() ? orderGraphMarkup(graph, this.graphSelected) : orderDotsMarkup(graph)) : '';
    // USUARIO-NUEVO A7 (10-nov): una orden con plan no es una tarjeta suelta
    // «Orden #N»: su entendimiento, el grafo y las tareas viajan DENTRO del
    // grupo plegable, entre el mensaje del usuario y la respuesta. En la
    // aprobación y en las aclaraciones el plan sigue fuera (es la decisión).
    const tasks = this.plan?.tasks ?? [];
    const planInside = tasks.length > 0 && !['awaiting-approval', 'clarifying', 'planning'].includes(this.phase);
    const prelude = planInside
      ? (this.plan?.understanding
          ? `<div class="card"><div class="section-label" style="margin-bottom:6px">Entendimiento</div>${this.clampedMarkup(this.plan.understanding)}</div>`
          : '') + top + this.planTasksMarkup(tasks)
      : top;
    return this.renderActivityContent(prelude, planInside);
  }

  /** Nodo del grafo cuyo detalle se está viendo (sobrevive a los repintados). */
  private graphSelected = '';

  /**
 * T8: el agente pidió ver el grafo de su orden (`open_view`
   * con `order_graph`). Igual que el interruptor «Grafo»: enciende la vista y
   * repinta; no cambia permisos, aprobaciones ni la orden.
   */
  public showOrderGraph(): void {
    setGraphEnabled(true);
    const box = this.container.querySelector<HTMLInputElement>('#chk-order-graph');
    if (box) box.checked = true;
    this.renderBody();
    this.container.querySelector<HTMLElement>('[data-order-graph]')?.scrollIntoView({ block: 'nearest' });
  }

  /** Muestra el detalle de un nodo del grafo sin repintar la orden. */
  private selectGraphNode(key: string): void {
    this.graphSelected = key;
    const graph = this.container.querySelector<HTMLElement>('[data-order-graph]');
    if (!graph) return;
    graph.querySelectorAll<SVGGElement>('[data-graph-node]').forEach((n) => n.classList.toggle('sel', n.dataset.graphNode === key));
    const known = !!graph.querySelector(`[data-info="${CSS.escape(key)}"]`);
    graph.querySelectorAll<HTMLElement>('[data-info]').forEach((d) => (d.hidden = known ? d.dataset.info !== key : d.dataset.info !== ''));
  }

  private renderActivityContent(prelude = '', hasPlan = false): string {
    const a = this.actividadActual();
    if (!this.events.length && !hasPlan) {
      return this.phase === 'running'
        ? '<div class="subtle" style="padding:4px 2px">Trabajando…</div>'
        : prelude;
    }

    const fuera: string[] = [];
    const workspaceDiagnostic = this.phase === 'error' ? workspaceRestoreDiagnostic(this.events) : null;
    if (workspaceDiagnostic && this.orderId) {
      const state = this.workspaceRestoreState?.orderId === this.orderId ? this.workspaceRestoreState : null;
      fuera.push(`<div class="card col" style="gap:8px;border-color:var(--danger)" data-workspace-permissions>
        <span class="card__title">Permisos del espacio rechazados</span>
        <span class="card__subtitle" style="white-space:pre-wrap">${esc(workspaceDiagnostic)}</span>
        <span class="card__subtitle">Restaurar aplica los mismos permisos privados que al crear el espacio. La orden permanece detenida.</span>
        <button class="btn" id="btn-workspace-restore" ${state?.busy || state?.restored ? 'disabled' : ''}>${state?.busy ? 'Restaurando permisos…' : 'Restaurar permisos del espacio'}</button>
        <span role="status" style="white-space:pre-wrap">${esc(state?.message ?? '')}</span>
      </div>`);
    }

    // El último aviso local sigue visible aunque se pliegue la actividad.
    // Cada intento conserva su entrada histórica dentro del detalle.
    const avisoLocal = a.operaciones.filter((op) => op.id.startsWith('local-json:')).slice(-1)[0];
    if (avisoLocal) {
      fuera.push(`<div role="status" data-local-json-notice="${escapeAttribute(avisoLocal.id)}" data-local-json-order="${this.orderId}">${
        cardMarkup(avisoLocal.titulo, avisoLocal.detalle, MissionControlPanel.COLOR_ESTADO[avisoLocal.estado])
      }</div>`);
    }

    if (this.events.some(e => e.kind === 'budget_blocked_v1' || (e.kind === 'order_failed' && e.payload?.cause === 'paid_budget_exhausted'))) {
      fuera.push('<button class="btn btn--primary" data-authorize-budget>Autorizar más llamadas</button>');
    }
    // 1. Lo que espera una decisión del usuario. Nunca se pliega.
    // (tanda 1): una solicitud del motor se contesta aquí mismo,
    // como en Claude Code o Codex; antes había que abrir Avisos, que llevaba
    // al Monitor y sacaba al usuario de la conversación.
    for (const p of a.pendientes) {
      if (p.approvalId === undefined) {
        fuera.push(cardMarkup(p.titulo, p.detalle, 'var(--accent)'));
        continue;
      }
      const st = this.threadApprovals.get(p.approvalId);
      const busy = st?.busy ? 'disabled' : '';
      fuera.push(`<div class="card col" style="gap:8px;padding:10px 12px" data-thread-approval="${p.approvalId}">
        <span style="font-size:13px;font-weight:550;color:var(--accent)">${esc(p.titulo)}</span>
        ${p.detalle ? `<span class="subtle" style="font-size:11px;word-break:break-word">${esc(p.detalle)}</span>` : ''}
        <div class="row" style="gap:8px">
          <button class="btn btn--primary btn--sm" data-thread-approve="${p.approvalId}" ${busy} title="Permite esta acción una vez">Aprobar</button>
          <button class="btn btn--sm" data-thread-reject="${p.approvalId}" ${busy} title="No la ejecuta; el agente recibe el rechazo">Rechazar</button>
        </div>
        ${st?.error ? `<span role="alert" style="font-size:11px;color:var(--danger);white-space:pre-wrap">${esc(st.error)}</span>` : ''}
      </div>`);
    }

    // 2. Bloqueos vigentes: qué pasa, qué implica y qué se puede hacer. El
    //    stack se queda dentro del detalle; el HECHO de que falló, no.
    //
    //    Fuera del bloque van los TRES primeros. La orden 437 producía diez
    //    bloqueos —un fallo real y nueve consecuencias— y apilarlos empujaba
    //    fuera de pantalla la actividad y la respuesta: un muro rojo no es más
    //    honesto que un resumen, sólo es más difícil de leer. Los demás siguen
    //    enteros dentro de la actividad, y el contador dice cuántos son.
    const vigentes = act.bloqueosVigentes(a);
    for (const b of vigentes.slice(0, MissionControlPanel.BLOQUEOS_A_LA_VISTA)) {
      fuera.push(
        cardMarkup(b.titulo, [primeraLinea(b.detalle), b.accion].filter(Boolean).join('\n'), 'var(--danger)')
      );
    }
    // USUARIO-NUEVO B: sin git no hay worktrees para delegar; se ofrece la
    // acción que ya existe («Iniciar git aquí»), no se trabaja en silencio en
    // el mismo espacio.
    if (this.events.some((e) => e.kind === 'delegation_blocked_v1' && eventPayload(e).cause === 'no_git')) {
      fuera.push(`<div class="card" data-delegation-no-git>
        <div class="card__subtitle">Para delegar, cada subtarea necesita su propio worktree de git.</div>
        <div class="row" style="margin-top:8px"><button class="btn btn--sm" data-git-init title="Crea un repositorio git local (git init) en la carpeta de trabajo; no sube nada">Iniciar git aquí</button></div>
      </div>`);
    }
    if (vigentes.length > MissionControlPanel.BLOQUEOS_A_LA_VISTA) {
      const resto = vigentes.length - MissionControlPanel.BLOQUEOS_A_LA_VISTA;
      fuera.push(
        `<div class="subtle" style="font-size:11px;padding:2px 2px">y ${resto} bloqueo(s) más, dentro de la actividad</div>`
      );
    }

    // 3. El grupo plegable (A7, 10-nov): UNA línea con lo que hizo
    // («Ejecutó 4 comandos · escribió 2 archivos · 38 s»), plegada al
    // terminar. Si no hubo trabajo (un «Hola»), no se pinta nada: los eventos
    // del motor quedan en «Registro completo» y en «Salida del motor».
    if (!act.hayTrabajo(a) && !hasPlan && this.phase !== 'running') return fuera.join('');
    const abierto = this.activityOpen === null ? !act.deberiaPlegarse(a) : this.activityOpen;
    const estadoDistinto = a.estado !== 'completado' && a.estado !== 'ejecutando';
    const chip = estadoDistinto
      ? `<span class="badge" style="color:${MissionControlPanel.COLOR_ESTADO_TURNO[a.estado]}">${MissionControlPanel.ETIQUETA_ESTADO_TURNO[a.estado]}</span>`
      : '';
    const orden = this.orderId ? `Orden #${this.orderId}` : '';

    const bloque = `<details id="turn-activity" ${abierto ? 'open' : ''} class="work-group" style="border:1px solid var(--border-subtle);border-radius:8px"${orden ? ` title="${escapeAttribute(orden)}"` : ''}>
      <summary class="row" style="gap:10px;align-items:center;cursor:pointer;padding:7px 10px;list-style:none;user-select:none"
               aria-label="Lo que hizo el agente en este turno">
        ${this.phase === 'running' ? '<span class="spinner"></span>' : icons.chevronDown(13)}
        <span class="work-group__summary" style="font-size:12.5px;font-weight:550;color:var(--fg-muted, var(--fg))">${esc(act.resumenTrabajo(a))}</span>
        ${chip}
      </summary>
      <div class="col" style="gap:8px;padding:8px 10px 10px 10px">
        ${orden ? `<div class="subtle" style="font-size:11px">${esc(orden)}</div>` : ''}
        ${prelude}
        ${this.renderActivityBody(a)}
      </div>
    </details>`;

    return [...fuera, bloque].join('');
  }

  private workspaceRestoreState: {orderId: number; busy: boolean; restored: boolean; message: string} | null = null;

  private async restoreWorkspacePermissions(): Promise<void> {
    if (!this.core || !this.orderId || this.phase !== 'error' || !workspaceRestoreDiagnostic(this.events)) return;
    if (this.workspaceRestoreState?.orderId === this.orderId && (this.workspaceRestoreState.busy || this.workspaceRestoreState.restored)) return;
    const state = {orderId: this.orderId, busy: true, restored: false, message: ''};
    this.workspaceRestoreState = state;
    this.renderBody();
    try {
      const result = await this.core.restoreWorkspacePermissions(state.orderId);
      if (!result.restored) throw new Error('El motor no confirmó la restauración');
      state.restored = true;
      state.message = `${result.message}\n${result.root}`;
    } catch (error) {
      state.message = `No se pudieron restaurar los permisos: ${String(error)}`;
    } finally {
      state.busy = false;
      if (this.orderId === state.orderId) this.renderBody();
    }
  }

  /** El detalle: progreso, operaciones en orden, razonamiento y lo dudoso. */
  private renderActivityBody(a: act.ActividadTurno): string {
    const partes: string[] = [];

    partes.push(`<div class="row" style="gap:8px;align-items:center;flex-wrap:wrap">
      <input class="input" id="activity-filter" placeholder="Filtrar la actividad"
             value="${escapeAttribute(this.activityFilter)}" style="flex:1;min-width:140px;font-size:11px" />
      <button class="btn" id="btn-activity-copy" title="Copia la actividad al portapapeles" style="font-size:11px">Copiar</button>
      <button class="btn btn--ghost" id="btn-activity-log" title="Abre el registro completo de la actividad" style="font-size:11px">Registro completo</button>
    </div>`);

    // CHAT-PD-1, hallazgo H-1 de la auditoría de la cabina (09-09): el contador
    // de fuera dice «y N bloqueo(s) más, dentro de la actividad» y aquí no se
    // pintaba ninguno. Los bloqueos 4..N no aparecían en NINGÚN sitio del
    // bloque: sólo salían al pulsar «Copiar» o al abrir la salida del motor.
    // Una promesa que el detalle no cumple es peor que no hacerla — y peor aún
    // en la parte que existe justo para que un fallo no se pierda.
    //
    // Se pintan TODOS los vigentes, con los que ya están fuera marcados como
    // tales para que nadie los cuente dos veces.
    const vigentesEnDetalle = act.bloqueosVigentes(a);
    if (vigentesEnDetalle.length) {
      partes.push(`<div class="col" style="gap:6px">
        <div class="section-label">${vigentesEnDetalle.length} bloqueo(s) sin resolver</div>
        ${vigentesEnDetalle
          .map((b, i) => {
            const yaArriba = i < MissionControlPanel.BLOQUEOS_A_LA_VISTA;
            return cardMarkup(
              `${b.titulo}${yaArriba ? ' · ya visible arriba' : ''}`,
              [b.detalle, b.accion].filter(Boolean).join('\n'),
              'var(--danger)'
            );
          })
          .join('')}
      </div>`);
    }

    if (a.progreso.length) {
      partes.push(`<div class="col" style="gap:2px">
        ${a.progreso
          .map((p) => `<div class="subtle" style="font-size:11px">${esc(p)}</div>`)
          .join('')}
      </div>`);
    }

    const filtro = this.activityFilter.trim().toLowerCase();
    const visibles = filtro
      ? a.operaciones.filter((op) =>
          `${op.titulo} ${op.detalle} ${op.atribucion} ${op.stdout ?? ''} ${op.stderr ?? ''}`
            .toLowerCase()
            .includes(filtro)
        )
      : a.operaciones;

    // Paginación: se pinta la COLA (lo más reciente) y se dice cuánto queda.
    const tope = MissionControlPanel.ACTIVITY_PAGE;
    const recortadas = !this.activityShowAll && visibles.length > tope;
    const lista = recortadas ? visibles.slice(visibles.length - tope) : visibles;

    if (recortadas) {
      partes.push(`<div class="row" style="gap:8px;align-items:center">
        <span class="subtle" style="font-size:11px">${visibles.length - tope} operación(es) anteriores sin pintar</span>
        <button class="btn btn--ghost" id="btn-activity-all" title="Muestra todas las entradas de actividad, no solo las recientes" style="font-size:11px">Ver todas</button>
      </div>`);
    }

    if (!lista.length && (filtro || this.phase === 'running')) {
      partes.push(`<div class="subtle" style="font-size:11px">${
        filtro ? 'Ninguna operación coincide con el filtro.' : 'Todavía no hay operaciones.'
      }</div>`);
    }

    // Orden cronológico, agrupando tramos consecutivos de la misma familia.
    let i = 0;
    while (i < lista.length) {
      const familia = lista[i].familia;
      let j = i;
      while (j < lista.length && lista[j].familia === familia) j += 1;
      const tramo = lista.slice(i, j);
      const cuerpo = tramo.map((op) => this.renderOperacion(op)).join('');
      if (tramo.length === 1) {
        partes.push(cuerpo);
      } else {
        const etiqueta = act.agruparOperaciones(tramo)[0]?.etiqueta ?? `${tramo.length} acciones`;
        const conFallo = tramo.some((op) => op.estado === 'fallo');
        // USUARIO-NUEVO B: una subtarea delegada que el usuario desplegó
        // mantiene abierto su tramo al repintar (al llegar sus operaciones).
        const conHijaAbierta = tramo.some((op) => !!op.ordenHija && this.childOpen.has(op.ordenHija));
        // Un tramo con un fallo dentro no se pliega: el ruido se esconde, el
        // fallo no.
        partes.push(`<details class="col" ${conFallo || conHijaAbierta ? 'open' : ''} style="gap:6px">
          <summary class="row" style="gap:8px;cursor:pointer;list-style:none;user-select:none;font-size:12px">
            ${icons.chevronDown(12)}<span>${esc(etiqueta)}</span>
            ${conFallo ? '<span class="badge" style="color:var(--danger)">con fallos</span>' : ''}
          </summary>
          <div class="col" style="gap:6px;margin-left:14px;padding-left:10px;border-left:2px solid var(--border-subtle)">${cuerpo}</div>
        </details>`);
      }
      i = j;
    }

    if (a.razonamiento) {
      const palabras = a.razonamiento.texto.trim().split(/\s+/).length;
      partes.push(`<details class="reasoning">
        <summary class="reasoning__summary">
          ${icons.brain(13)} Resumen de razonamiento del proveedor
          <span class="subtle" style="font-weight:400">· ${palabras} palabras · ${esc(a.razonamiento.procedencia)}</span>
        </summary>
        <div class="reasoning__body">${esc(a.razonamiento.texto)}</div>
      </details>`);
    }

    // A7 (10-nov): los eventos sin clasificar y los contadores del motor ya
    // no se pintan en la conversación; siguen enteros en «Registro completo»
    // (botón de arriba) y en «Salida del motor».
    return partes.join('');
  }

  /** Una operación: qué se hizo, cómo acabó y quién la hizo de verdad. */
  private renderOperacion(op: act.Operacion): string {
    const color = MissionControlPanel.COLOR_ESTADO[op.estado];
    const salida = [op.stdout, op.stderr].filter(Boolean).join('\n');
    const detalle = [op.detalle, salida].filter(Boolean).join('\n');
    const abrir = op.familia === 'archivo' ? op.detalle : undefined;
    // USUARIO-NUEVO B: una subtarea delegada se pinta en UNA línea (rol,
    // modelo, estado, duración) sin el contador de eventos del motor.
    const delegada = op.familia === 'subagente' && !!op.ordenHija;
    const tarjeta = cardMarkup(
      `${op.titulo}${op.eventos > 1 && !delegada ? ` · ${op.eventos} eventos` : ''}`,
      [detalle, op.atribucion].filter(Boolean).join('\n'),
      color,
      abrir,
      abrir ? artifactAction(this.events, abrir) : undefined
    );
    if (op.process) {
      const { id, generation, stopped } = op.process;
      const state = this.processCards.get(id);
      return `<div class="col" data-process-card="${escapeAttribute(id)}" data-generation="${generation}">
        ${tarjeta}
        <div class="row">
          <button type="button" class="btn btn--sm" data-process-action="logs" ${state?.busy ? 'disabled' : ''}>Ver salida</button>
          <button type="button" class="btn btn--sm" data-process-action="stop" ${stopped || state?.stopped || state?.busy ? 'disabled' : ''}>Detener</button>
        </div>
        <div role="status" class="subtle" style="white-space:pre-wrap">${esc(state?.message || '')}</div>
      </div>`;
    }
    if (!delegada) return tarjeta;
    // Desplegable a las operaciones REALES de su orden hija (sus eventos).
    const hija = op.ordenHija!;
    const cargado = this.childOps.get(hija);
    const cuerpo =
      cargado === undefined
        ? '<div class="subtle" style="font-size:11px">Despliégala para ver sus operaciones.</div>'
        : typeof cargado === 'string'
          ? `<div class="subtle" style="font-size:11px">${esc(cargado)}</div>`
          : cargado.length
            ? cargado.map((o) => this.renderOperacion(o)).join('')
            : '<div class="subtle" style="font-size:11px">Esta subtarea no registró operaciones.</div>';
    return `<details class="delegated-sub col" data-child-order="${hija}" ${this.childOpen.has(hija) ? 'open' : ''} style="gap:6px">
      <summary style="list-style:none;cursor:pointer" title="Orden #${hija}: despliega sus operaciones">${tarjeta}</summary>
      <div class="col" style="gap:6px;margin-left:14px;padding-left:10px;border-left:2px solid var(--border-subtle)">${cuerpo}</div>
    </details>`;
  }

  /** USUARIO-NUEVO B: operaciones de cada orden hija desplegada (o el motivo de no tenerlas). */
  private childOps = new Map<number, act.Operacion[] | string>();
  private processCards = new Map<string, { busy: boolean; stopped: boolean; message: string; cursor?: string }>();
  private childOpen = new Set<number>();

  /**
   * Contesta una solicitud del motor desde el hilo. La tarjeta desaparece
   * cuando llega `approval_resolved` en los eventos de la orden; si el motor
   * rechaza la respuesta (ya resuelta, orden terminada), se dice en la tarjeta.
   */
  private async resolveThreadApproval(id: number, approved: boolean): Promise<void> {
    if (!this.core || !Number.isSafeInteger(id) || id <= 0) return;
    if (this.threadApprovals.get(id)?.busy) return;
    this.threadApprovals.set(id, { busy: true, error: '' });
    this.paintEvents();
    try {
      await this.core.resolveApproval(id, approved);
      this.threadApprovals.set(id, { busy: true, error: '' });
    } catch (e) {
      this.threadApprovals.set(id, { busy: false, error: `No se pudo ${approved ? 'aprobar' : 'rechazar'}: ${String(e instanceof Error ? e.message : e)}` });
    }
    this.paintEvents();
  }

  private async loadChildOps(orderId: number): Promise<void> {
    if (!this.core) return;
    if (!this.childOps.has(orderId)) this.childOps.set(orderId, 'Cargando sus operaciones…');
    try {
      const evs = await this.core.orderEvents(orderId);
      this.childOps.set(orderId, act.construirActividad(evs, { ahora: Date.now(), vivo: false }).operaciones);
    } catch (e) {
      this.childOps.set(orderId, `No se pudieron leer sus operaciones: ${String(e instanceof Error ? e.message : e)}`);
    }
    this.paintEvents();
  }

  /**
   * Cablea el bloque de actividad tras cada repintado.
   *
   * El plegado del usuario se guarda en el panel (no en `localStorage`): es
   * una decisión de ESTE turno, y arrastrarla a la siguiente conversación
   * sería otra forma de decidir por él.
   */
  private bindActivity(host: HTMLElement): void {
    host.querySelectorAll<HTMLElement>('[data-thread-approve]').forEach(btn => btn.addEventListener('click', () => {
      void this.resolveThreadApproval(Number(btn.dataset.threadApprove), true);
    }));
    host.querySelectorAll<HTMLElement>('[data-thread-reject]').forEach(btn => btn.addEventListener('click', () => {
      void this.resolveThreadApproval(Number(btn.dataset.threadReject), false);
    }));
    host.querySelectorAll('[data-authorize-budget]').forEach(btn => btn.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('devagents:settings-section', { detail: 'governance' }));
    }));
    const det = host.querySelector<HTMLDetailsElement>('#turn-activity');
    if (det) {
      // A7 (10-nov, medido en vivo): un <details> pintado con `open` emite
      // `toggle` al insertarse. Contarlo como decisión del usuario fijaba
      // activityOpen=true mientras la orden corría y el grupo ya no se plegaba
      // al terminar. Solo cuenta un cambio respecto a como se pintó.
      const painted = det.open;
      det.addEventListener('toggle', () => {
        if (det.open === painted && this.activityOpen === null) return;
        this.activityOpen = det.open;
      });
    }
    // USUARIO-NUEVO B: cada subtarea delegada se despliega a sus operaciones;
    // se piden al abrirla (y al reabrir, por si seguía en marcha).
    host.querySelectorAll<HTMLDetailsElement>('details[data-child-order]').forEach((d) => {
      const hija = Number(d.dataset.childOrder);
      if (!Number.isFinite(hija) || hija <= 0) return;
      if (d.open && !this.childOps.has(hija)) void this.loadChildOps(hija);
      // Un <details> pintado abierto emite `toggle` al insertarse (A7): solo
      // cuenta un cambio respecto al último estado conocido.
      let last = d.open;
      d.addEventListener('toggle', () => {
        if (d.open === last) return;
        last = d.open;
        if (d.open) {
          this.childOpen.add(hija);
          void this.loadChildOps(hija);
        } else this.childOpen.delete(hija);
      });
    });
    const filtro = host.querySelector<HTMLInputElement>('#activity-filter');
    if (filtro) {
      filtro.addEventListener('input', () => {
        this.activityFilter = filtro.value;
        this.paintEvents();
      });
    }
    host.querySelector('#btn-activity-all')?.addEventListener('click', () => {
      this.activityShowAll = true;
      this.paintEvents();
    });
    for (const button of host.querySelectorAll<HTMLButtonElement>('[data-process-action]')) {
      button.addEventListener('click', async () => {
        const card = button.closest<HTMLElement>('[data-process-card]');
        const id = card?.dataset.processCard;
        const generation = Number(card?.dataset.generation);
        if (!this.core || !id || !Number.isSafeInteger(generation)) return;
        const action = button.dataset.processAction === 'stop' ? 'stop' : 'logs';
        const previous = this.processCards.get(id);
        if (previous?.busy) return;
        const state = { busy: true, stopped: previous?.stopped ?? false, message: previous?.message ?? '', cursor: previous?.cursor };
        this.processCards.set(id, state);
        this.paintEvents();
        try {
          const result = await this.core.controlProcess(action, id, generation, state.cursor);
          state.stopped = result.state !== 'running';
          if (result.log) {
            if (result.log.more) state.cursor = String(result.log.next_cursor);
            else state.cursor = undefined;
            state.message = (result.log.skipped ? 'Se descartó parte de la salida anterior.\n' : '') +
              (result.log.text || 'El proceso todavía no tiene salida registrada.');
          } else {
            state.message = result.state === 'stopped' ? 'Proceso detenido.' : 'El proceso ya terminó.';
          }
        } catch (error) {
          state.message = String(error instanceof Error ? error.message : error);
        } finally {
          state.busy = false;
          this.paintEvents();
        }
      });
    }
    host.querySelector('#btn-activity-copy')?.addEventListener('click', () => {
      const a = this.actividadActual();
      const texto = [
        act.resumenActividad(a),
        ...a.progreso,
        ...a.operaciones.map(
          (op) => `- [${op.estado}] ${op.titulo} · ${op.atribucion}${op.detalle ? ` — ${op.detalle}` : ''}`
        ),
        ...act.bloqueosVigentes(a).map((b) => `! ${b.titulo}: ${b.detalle}`),
      ].join('\n');
      void navigator.clipboard?.writeText(texto);
      notice('Actividad copiada al portapapeles.', 'info');
    });
    host.querySelector('#btn-activity-log')?.addEventListener('click', () => {
      // El registro íntegro vive en «Salida del motor», que ya recibe la
      // corriente y la traza enteras: plegar la conversación no borra nada,
      // sólo deja de repetirlo aquí. Se abre pulsando su propia pestaña en vez
      // de inventar un canal nuevo para lo mismo.
      const tab = document.querySelector<HTMLElement>('[data-bottom="engine"]');
      if (tab) tab.click();
      else notice('El panel «Salida del motor» no está disponible en esta vista.', 'info');
    });
  }



  private renderEventStream(): SafeHtml {
    const out: SafeHtml[] = [];
    let buffer: string[] = [];

    const flush = (): void => {
      if (!buffer.length) return;
      const text = buffer.join('');
      const words = text.trim().split(/\s+/).length;
      out.push(safeHtml`<details class="reasoning">
        <summary class="reasoning__summary">
          ${raw(icons.brain(13))} Razonamiento del modelo
          <span class="subtle" style="font-weight:400">· ${words} palabras</span>
        </summary>
        <div class="reasoning__body">${text}</div>
      </details>`);
      buffer = [];
    };

    for (const e of this.events) {
      if (String(e.kind || '') === 'reasoning_delta') {
        buffer.push(extractReasoning(e));
        continue;
      }
      flush();
      out.push(this.renderEvent(e));
    }
    flush();
    return joinHtml(out);
  }

  private renderEvent(e: OrderEvent): SafeHtml {
    const kind = String(e.kind || '');
    const color = /fail|error/i.test(kind)
      ? 'var(--danger)'
      : /pass|ok|done|complete/i.test(kind)
        ? 'var(--success)'
        : 'var(--fg-subtle)';
    // P3: los intentos fallidos de proveedor llevan `total_len`/`closed`/
    // `error_name` desde la orden 148 — la traza cruda debe decir eso, no
    // `empty` a secas. Es la misma función que la tarjeta del chat.
    let desc = describeEvent(e);
    if (kind === 'task_provider_failed') desc = describeProviderFailure(eventPayload(e));
    return safeHtml`<div class="row" style="gap:10px;align-items:flex-start;padding:2px 0">
      <span style="color:${color};min-width:120px">${kind}</span>
      <span class="subtle" style="min-width:90px">${String(e.source || '')}</span>
      <span class="truncate grow">${desc}</span>
    </div>`;
  }

  private bindRun(body: HTMLElement): void {
    body.querySelector('#plan-change-request')?.addEventListener('input', (event) => {
      this.planChangeDraft = (event.target as HTMLTextAreaElement).value;
      const button = body.querySelector<HTMLButtonElement>('#btn-plan-changes');
      if (button) button.disabled = !this.planChangeDraft.trim();
    });
    body.querySelector('#btn-plan-changes')?.addEventListener('click', () => void this.requestPlanChanges());
    body.querySelector('#btn-approve')?.addEventListener('click', () => void this.approve());
    // El borrador del observable vive en `expectedDraft`, no solo en el DOM:
    // cualquier renderBody entre que el usuario escribe y aprueba re-crea el
    // textarea y se llevaria el texto (medido en vivo: declaracion perdida).
    body.querySelector('#order-expected')?.addEventListener('input', (e) => {
      this.expectedDraft = (e.target as HTMLTextAreaElement).value;
    });
    body.querySelector('#btn-discard')?.addEventListener('click', () => void this.cancel());
    body.querySelector('#btn-compact')?.addEventListener('click', () => void this.compactConversation());
    body.querySelector('#btn-auto-compact')?.addEventListener('click', () => void this.compactConversation());
    body.querySelector('#btn-dismiss-compact')?.addEventListener('click', () => {
      // «Posponer» apaga el disparo automático de ESTE hilo, no de la sesión:
      // el criterio de un hilo no dice nada del siguiente.
      this.stopAutoCompactTimer();
      this.autoCompact = autoc.posponer(this.autoCompact);
      this.renderBody();
    });
    // Reintentar es volver a lanzar el ÚLTIMO mensaje del usuario dentro del
    // mismo hilo, no empezar de cero. Hay dos botones que hacen esto y uno solo
    // llega a verse cada vez: el de la fase de error (`btn-mission-retry`) y el
    // que va pegado al turno que falló (`btn-turn-retry`, D3). Comparten
    // manejador para que no puedan divergir.
    const reintentar = (): void => {
      const last = [...this.turns].reverse().find((t) => t.role === 'user');
      this.errorText = '';
      // El turno fallido deja de estar marcado: si el reintento vuelve a
      // fallar, se marcará el nuevo. Sin esto quedarían dos botones a la vez.
      this.turns = this.turns.map((t) => (t.failed ? { ...t, failed: false } : t));
      if (last) void this.submit(last.text);
      else this.setPhase('chat');
    };
    body.querySelector('#btn-mission-retry')?.addEventListener('click', reintentar);
    body.querySelector('#btn-turn-retry')?.addEventListener('click', reintentar);
    // A3 (10-nov): «Heredar mis instrucciones» guarda el ajuste y reintenta;
    // «Ahora no» deja el aislamiento y dice dónde cambiarlo.
    body.querySelector<HTMLButtonElement>('#btn-turn-inherit')?.addEventListener('click', async (ev) => {
      const btn = ev.currentTarget as HTMLButtonElement;
      btn.disabled = true;
      try {
        await this.core?.setExternalLimits({ inherit_personal_context: true });
        notice('Los agentes externos usarán tus instrucciones personales. Puedes cambiarlo en Configuración › Agentes externos.', 'info');
        reintentar();
      } catch (e) {
        btn.disabled = false;
        notice(`No se pudo guardar el ajuste: ${String(e)}`, 'error');
      }
    });
    body.querySelector('#btn-turn-inherit-no')?.addEventListener('click', () => {
      this.inheritDeclined = true;
      this.renderBody();
    });
    body.querySelector('#btn-turn-open-agents')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('devagents:settings-section', { detail: 'agents' }));
    });
    // A6 (10-nov): otro modelo gratuito disponible y el mismo mensaje.
    body.querySelector<HTMLButtonElement>('#btn-turn-other-free')?.addEventListener('click', async (ev) => {
      const btn = ev.currentTarget as HTMLButtonElement;
      const next = this.nextFreeModel();
      if (!next) return;
      btn.disabled = true;
      try {
        await this.applyOrderModelChoice(next.provider, next.model);
        this.pinnedRoles.plan = MissionControlPanel.executorOnlyCli(next.provider) ? this.pinnedRoles.plan : `${next.provider}|${next.model}`;
        this.updateModelChip();
        notice(`Probando con ${this.shortModel(`${next.provider}|${next.model}`)}.`, 'info');
        reintentar();
      } catch (e) {
        btn.disabled = false;
        notice(`No se pudo cambiar de modelo: ${String(e)}`, 'error');
      }
    });
    // CHECKPOINT-T2: reanudar una orden interrumpida NO es reintentar el último
    // mensaje — es continuar su plan ya aprobado desde la primera tarea no
    // completada del checkpoint persistido, sin rehacer las ya hechas.
    body.querySelector('#btn-order-resume')?.addEventListener('click', () => void this.resumeOrder());
    // AUDIT-UNAVAILABLE-P0: reintento manual de la auditoría — mismo camino de
    // reanudación que 'interrupted'; el motor solo re-corre las tareas de
    // auditoría sin veredicto (el resto se restaura desde el checkpoint).
    body.querySelector('#btn-audit-retry')?.addEventListener('click', () => void this.resumeOrder());
    // El borrador se respalda al teclear: un renderBody() a mitad de edición
    // (un evento entrante, un tick de actividad) recreaba el textarea y se
    // llevaba el texto editado — mismo pozo que #order-expected en S21-D1.
    body.querySelector<HTMLTextAreaElement>('#plan-edit')?.addEventListener('input', (ev) => {
      this.planEditDraft = (ev.target as HTMLTextAreaElement).value;
    });
    body.querySelector('#btn-plan-save')?.addEventListener('click', () => {
      const ta = body.querySelector<HTMLTextAreaElement>('#plan-edit');
      const msg = body.querySelector<HTMLElement>('#plan-msg');
      if (!ta || !this.core) return;
      const say = (t: string, ok: boolean): void => {
        if (msg) {
          msg.textContent = t;
          msg.style.color = ok ? 'var(--success)' : 'var(--danger)';
        }
      };
      // Se valida aquí antes de mandarlo: el motor rechaza el JSON inválido con
      // un error genérico, y decirle al usuario "línea 12" es más útil.
      try {
        JSON.parse(ta.value);
      } catch (e) {
        say(`JSON inválido: ${String(e)}`, false);
        return;
      }
      void this.core
        .setOrderPlan(this.orderId, ta.value)
        .then(async () => {
          this.plan = (await this.core!.getPlan(this.orderId)) as OrderPlan;
          this.planEditDraft = null;
          say('Plan guardado en el motor.', true);
        })
        .catch((e) => say(String(e), false));
    });
    body.querySelector('#btn-revert')?.addEventListener('click', () => void this.revertToCheckpoint());
    body.querySelector('#btn-mission-reset')?.addEventListener('click', () => this.reset());
    body.querySelector('#btn-workspace-restore')?.addEventListener('click', () => void this.restoreWorkspacePermissions());
    body.querySelector('#btn-ship')?.addEventListener('click', () => void this.shipOrder());
    body.querySelector('#btn-ship-cred')?.addEventListener('click', () => void this.saveForgeCredential());
    body.querySelectorAll<HTMLElement>('.btn-pr-merge').forEach((b) =>
      b.addEventListener('click', () => void this.mergePr(Number(b.dataset.prId)))
    );
    body.querySelectorAll<HTMLElement>('.pr-url').forEach((b) =>
      b.addEventListener('click', () => {
        const u = b.dataset.url;
        if (u) void this.core?.openPath(u);
      })
    );
    body.querySelector('#btn-send-answers')?.addEventListener('click', () => {
      const answers: { question_id: string; answer: string }[] = [];
      body.querySelectorAll<HTMLInputElement | HTMLSelectElement>('[data-answer]').forEach((el) => {
        answers.push({ question_id: el.dataset.answer || '', answer: el.value });
      });
      void this.sendAnswers(answers);
    });
    // E5.18: tarjeta comparativa — «Elegir este» fusiona en el motor; los
    // archivos despliegan su diff de solo lectura (diff_viewer.previewHtml).
    body.querySelectorAll<HTMLElement>('.bon-choose').forEach((b) =>
      b.addEventListener('click', () => void this.chooseBonCandidate(Number(b.dataset.cand)))
    );
    body.querySelectorAll<HTMLElement>('.bon-files').forEach((b) =>
      b.addEventListener('click', () => {
        const id = Number(b.dataset.cand);
        this.bonFilesOpen = this.bonFilesOpen === id ? null : id;
        this.renderBody();
      })
    );
    body.querySelectorAll<HTMLElement>('.bon-file').forEach((b) =>
      b.addEventListener('click', () => void this.showBonDiff(Number(b.dataset.cand), b.dataset.path || ''))
    );
    body.querySelector('#bon-diff-close')?.addEventListener('click', () => {
      this.bonDiffHtml = null;
      this.renderBody();
    });
  }

  // --- Ciclo de la orden ----------------------------------------------------

  private errorText = '';

  /**
   * @param text     Lo que se manda al motor (puede llevar adjuntos anexados).
   * @param display  Lo que se pinta en la burbuja. Sin él se usa `text`, y un
   *                 archivo de 2000 líneas acabaría dentro de la burbuja.
   */
  /** Mensajes escritos mientras el agente trabajaba; salen en orden al terminar. */
  private sendQueue: string[] = [];
  private sendChecking = false;

  /** Pinta la cola encima del compositor (cada mensaje con su ×). */
  private renderSendQueue(): void {
    const input = this.container?.querySelector?.<HTMLTextAreaElement>('#mission-composer-input');
    if (!input?.parentElement) return;
    let host = this.container.querySelector<HTMLElement>('#composer-queue');
    if (!host) {
      host = document.createElement('div');
      host.id = 'composer-queue';
      host.className = 'composer-queue';
      host.setAttribute('aria-live', 'polite');
      input.parentElement.insertBefore(host, input);
    }
    host.hidden = this.sendQueue.length === 0;
    host.innerHTML = this.sendQueue.map((t, i) => `<div class="composer-queue__item">
        <span class="composer-queue__tag">En cola</span>
        <span class="composer-queue__text" title="${escapeAttribute(t)}">${esc(t)}</span>
        <button class="composer-queue__x" data-queue-index="${i}" title="Quitar de la cola" aria-label="Quitar de la cola">×</button>
      </div>`).join('');
    host.querySelectorAll<HTMLButtonElement>('[data-queue-index]').forEach((b) => b.addEventListener('click', () => {
      this.sendQueue.splice(Number(b.dataset.queueIndex), 1);
      this.renderSendQueue();
    }));
  }

  /** Al quedar libre el agente, sale el siguiente mensaje de la cola. */
  private draining = false;
  private drainSendQueue(): void {
    if (this.sendQueue.length === 0 || this.sendChecking || this.draining) return;
    if (['planning', 'clarifying', 'running', 'best-of-n', 'awaiting-approval'].includes(this.phase)) return;
    this.draining = true;
    void this.waitEngineIdle().then(() => {
      this.draining = false;
      if (this.sendQueue.length === 0 || this.sendChecking) return;
      if (['planning', 'clarifying', 'running', 'best-of-n', 'awaiting-approval'].includes(this.phase)) return;
      this.submitQueued();
    });
  }

  /**
   * 10-nov (orden 940): la interfaz ve la respuesta un instante antes de que
   * el motor cierre la orden; enviar en ese hueco chocaba con «plan already
   * in progress». Se espera (máx. ~15 s) a que el motor termine de planificar.
   */
  private async waitEngineIdle(): Promise<void> {
    if (!this.core || typeof this.core.pollPlan !== 'function') return;
    for (let i = 0; i < 50; i++) {
      const st = await this.core.pollPlan().catch(() => ({ done: true, ok: false }));
      if (st?.done !== false) return;
      await new Promise((r) => window.setTimeout(r, 300));
    }
  }

  private submitQueued(): void {
    const next = this.sendQueue.shift()!;
    this.renderSendQueue();
    void this.submit(next).then((started) => {
      // Si no arrancó (configuración denegada…), vuelve al principio de la cola
      // y el aviso de submit dice por qué; no se reintenta en bucle.
      if (started === false) {
        this.sendQueue.unshift(next);
        this.renderSendQueue();
      }
    });
  }

  private setSendChecking(checking: boolean): void {
    this.sendChecking = checking;
    const btn = this.container?.querySelector?.<HTMLButtonElement>('#btn-mission-send');
    if (!btn) return;
    // Solo un indicador: nunca debe poder romper un envío.
    try {
      if (checking) btn.setAttribute?.('aria-busy', 'true');
      else btn.removeAttribute?.('aria-busy');
      btn.classList?.toggle?.('is-checking', checking);
      btn.title = checking ? 'Comprobando la configuración con el motor…' : 'Envía el mensaje o lanza la orden';
    } catch {
      // Elementos simulados de las pruebas o un botón ya retirado: se ignora.
    }
  }

  /** Devuelve false si la orden NO arrancó (el llamador conserva el texto); si arrancó, nada. */
  public async submit(text: string, display?: string, pendingAttachments?: Array<{ name: string; content: string } | ImageAttachment>): Promise<boolean | void> {
    let instruction = text;
    if (this.pendingIssue) {
      try { instruction = issueInstruction(text, this.pendingIssue.prompt); }
      catch (error) { notice(String(error), 'error'); return false; }
    }
    // CHAT-PD-1: un envío nuevo es un turno nuevo; su actividad arranca con el
    // plegado automático, no con el del turno anterior.
    this.activityOpen = null;
    this.activityFilter = '';
    this.activityShowAll = false;
    if (!this.core) {
      this.fail('El puente con el motor no está disponible.');
      return false;
    }
    if (this.phase === 'planning' || this.phase === 'clarifying' || this.phase === 'running' || this.phase === 'best-of-n') {
      // P0.2b: misma regla para llamadas programáticas que no pasan por
      // `trigger` — sin el aviso, un envío tragado en silencio parecía enviado.
      notice('Hay una orden en curso: el mensaje no se envió. Espera a que termine o cancélala.', 'info');
      return false;
    }
    const configurationEpoch = this.orderEpoch;
    // B1d (11-nov): en Directo/DevAgents la foto del proyecto se pide YA, en
    // paralelo con la comprobación de configuración (que va por la cola del
    // motor), y se espera justo antes de enviar. Medido en una copia del
    // proyecto de prueba: ~0,35-0,6 s de git por foto; así no se suma al
    // «Hola». El resultado (o el motivo del fallo) se guarda tal cual.
    // Un fallo síncrono del puente (p. ej. un núcleo sin `createCheckpoint`)
    // llega como rechazo y se guarda igual: nunca rompe el envío.
    const core = this.core;
    const checkpointTask = this.directMode
      ? (async () => core.createCheckpoint(''))().then(
          (ck) => ({ ck, error: '' }),
          (e: unknown) => ({ ck: null, error: String(e) })
        )
      : null;
    // Mientras el motor comprueba la configuración (al arrancar tarda varios
    // segundos), el botón lo dice: antes no pasaba nada visible.
    this.setSendChecking(true);
    try {
      await this.restoreSavedOrderModel().catch(() => undefined);
      const check = await this.core.orderPreflight();
      this.showConfiguration(check);
      if (!check.allowed) {
        notice(check.issues.map(i => `${i.role}: ${i.provider}/${i.model}. ${i.reason}. ${i.action}`).join('\n'), 'error');
        return false;
      }
    } catch (error) { notice(`No se pudo comprobar la configuración: ${String(error)}`, 'error'); return false; }
    finally { this.setSendChecking(false); }
    if (this.orderEpoch !== configurationEpoch || ['planning', 'clarifying', 'running', 'best-of-n'].includes(this.phase)) {
      // 8-nov (propietario: «no funcionó el envío de mis primeros dos mensajes»): este
      // envío se perdía EN SILENCIO —sin orden, sin aviso y con el compositor
      // ya vacío— si la conversación cambiaba mientras se comprobaba la
      // configuración (p. ej. al restaurar la sesión en el arranque, cuando el
      // motor tarda). Ahora se avisa, queda en el diagnóstico y el texto vuelve.
      console.warn('[envío] descartado: la conversación cambió durante la comprobación de configuración');
      notice('No se envió: la conversación cambió mientras se comprobaba la configuración. Tu mensaje sigue en el compositor; vuelve a enviarlo.', 'info');
      return false;
    }
    const epoch = ++this.orderEpoch;
    this.cancelPending = false;
    this.cancelError = '';
    // la orden anterior pasa a su bloque plegado ANTES de limpiar
    // nada. Antes se vaciaban events/plan aquí y desaparecían Entendimiento,
    // Plan, Actividad y Punto de control: solo quedaban los turnos de texto.
    this.archiveCurrentOrder();
    this.setPhase('planning');
    this.toggleCancel(true);
    this.startedAt = Date.now();
    this.events = [];
    this.lastEventId = 0;
    this.plan = null;
    this.streamText = '';
    // E5.18: una orden nueva no hereda la tarjeta comparativa de la anterior.
    this.bonData = null;
    this.bonBusy = false;
    this.bonError = '';
    this.bonFilesOpen = null;
    this.bonDiffHtml = null;
    // B2/E2.4: snapshot del pin que vale para ESTA orden. Si el usuario cambia
    // el selector después, la tarjeta sigue diciendo con qué pin se envió.
    this.orderPin = this.pinnedRoles.plan;
    this.turns.push({ role: 'user', text: display ?? text });

    try {
      // El motor agrupa las órdenes por `conversation_id` y le pasa al planner
      // el historial completo de esa conversación (`loadConversationHistory` en
      // c_api.zig). Estaba implementado desde FASE-AGENTIC-1, pero la cabina
      // mandaba siempre la cadena vacía, así que cada mensaje llegaba huérfano
      // y el agente no recordaba nada de lo anterior.
      // E5.18: el selector del compositor pide N candidatas (0 = apagado); el
      // input opcional fija la lista explícita [{provider,model}] — vacío
      // significa que los miembros salen del enjambre configurado.
      const bon = Number(this.container.querySelector<HTMLSelectElement>('#sel-best-of-n')?.value ?? 0) || 0;
      const bonMembers = (this.container.querySelector<HTMLInputElement>('#inp-bon-members')?.value ?? '').trim();
      const bonOpts = {
        waitForPlanApproval: this.planOnly,
        ...(bon >= 2 ? { bestOfN: bon, bestOfNMembers: bonMembers } : {}),
        attachments: (pendingAttachments ?? []).filter((a): a is ImageAttachment => 'data_base64' in a)
          .map((a) => ({ name: a.name, data_base64: a.data_base64 })),
      };
      // USUARIO-NUEVO B (10-nov): en DevAgents lo que hagan las subtareas se
      // integra en la carpeta del proyecto. El punto de control se toma ANTES,
      // con el mismo mecanismo que al aprobar un plan, para que «Revertir los
      // archivos» deshaga también lo integrado. Sin git falla y se dice; la
      // delegación tampoco se hará (necesita worktrees).
      // B1d (11-nov, propietario: «que funcione como Codex o Claude Code»): también
      // en Directo, que escribe en la carpeta en esta misma fase. Uno por
      // vuelta. Sin git NO se bloquea el envío ni se avisa aquí: el motivo se
      // guarda y solo se muestra si la vuelta llega a escribir archivos.
      this.turnCheckpoint = !!checkpointTask;
      this.checkpointAttempted = !!checkpointTask;
      if (checkpointTask) {
        this.checkpoint = null;
        this.checkpointRoot = '';
        this.checkpointMsg = '';
        const { ck, error } = await checkpointTask;
        this.checkpointError = error;
        if (ck) {
          this.checkpoint = { sha: ck.sha, untracked: ck.untrackedCount };
          this.checkpointRoot = ck.root;
        }
      }
      const { orderId } = await this.core.submitOrder(instruction, 'default', this.conversationId,
        { ...bonOpts, issueRequest: this.pendingIssue?.request });
      this.pendingIssue = null;
      if (pendingAttachments) {
        this.attachments = this.attachments.filter((a) => !pendingAttachments.includes(a));
        this.renderChips();
      }
      if (!this.isPlanningEpoch(epoch)) return;
      this.orderId = orderId;
      this.expectedDraft = '';
      this.planEditDraft = null;
      this.planChangeDraft = '';
      this.renderBody();
      // QA primerizo (10-nov): quien acaba de enviar quiere ver su mensaje y
      // la respuesta; la vista se quedaba arriba, en el primer mensaje.
      this.scrollThreadToEnd();
      // P3: la orden ya existe en el motor. `setPhase('planning')` se emitió
      // ANTES de crear la sesión, así que la barra lateral no tenía fila que
      // enseñar hasta que el plan terminaba. Este aviso la refresca al enviar.
      this.hooks.onActivity?.('status', this.phase);
      await this.waitForPlan(epoch, orderId);
    } catch (e) {
      if (!this.isPlanningEpoch(epoch)) return;
      this.fail(String(e));
    }
  }

  /** Sondea la planificación hasta que el hilo del motor termina. */
  private async waitForPlan(epoch: number, orderId: number): Promise<void> {
    if (!this.core) return;
    const started = Date.now();
    // Techo de 5 minutos: una planificación más larga que eso indica que el
    // proveedor no responde, y conviene decírselo al usuario en vez de girar.
    // en Directo el modelo TRABAJA en este mismo hilo (lee, edita,
    // ejecuta), así que el techo sube a 30 minutos; «Detener» sigue valiendo.
    const ceiling = (this.directMode ? 30 : 5) * 60 * 1000;
    while (Date.now() - started < ceiling) {
      await sleep(400);
      if (!this.isCurrentPlan(epoch, orderId)) return;
      this.tickElapsed();
      // las órdenes conversacionales no despachan tareas, así que
      // `startEventLoop` (que solo arranca en `approve`) jamás sondeaba sus
      // eventos: el content_delta quedaba EN LA BASE pero «Salida del motor»
      // seguía en «Sin salida todavía». Sondear aquí mismo — en cada tick de
      // la planificación — trae los deltas en cuanto existen, incluido el
      // que llega antes del primer tick de cualquier otro poll (medido:
      // orden #405, delta en events, panel vacío). absorbStream filtra los
      // content_delta y publica; los no-content_delta se acumulan para la
      // traza igual que en el bucle de despacho.
      await this.drainNewEvents(epoch, orderId);
      if (!this.isCurrentPlan(epoch, orderId)) return;
      let poll: { done: boolean; ok: boolean };
      try {
        poll = await this.core.pollPlan();
      } catch (e) {
        if (!this.isCurrentPlan(epoch, orderId)) return;
        this.fail(String(e));
        return;
      }
      if (!this.isCurrentPlan(epoch, orderId)) return;
      if (!poll.done) continue;

      // Fetch INMEDIATO al terminar: el delta final puede llegar con la
      // propia respuesta de pollPlan, y esperar 400 ms al siguiente giro
      // es justo la ventana que describía.
      await this.drainNewEvents(epoch, orderId);
      if (!this.isCurrentPlan(epoch, orderId)) return;

      if (!poll.ok) {
        // PLAN-CANCEL: un poll !ok tras pedir la cancelación NO es un fallo del
        // proveedor — el usuario pidió parar; decir otra cosa sería mentir.
        if (this.cancelPending) {
          // USUARIO-NUEVO B: en Directo/DevAgents no hay planificación que
          // cancelar: se detuvo el trabajo del modelo (y sus subtareas).
          this.fail(this.directMode ? 'Detenido a petición tuya: el modelo y sus subtareas se pararon; no se integró nada de lo que quedaba en marcha.' : 'La planificación fue cancelada.');
        } else {
          this.fail('La planificación falló. Revisa que haya una clave API válida y modelos en el catálogo.');
        }
        return;
      }
      try {
        const plan = (await this.core.getPlan(orderId)) as OrderPlan;
        if (!this.isCurrentPlan(epoch, orderId)) return;
        this.plan = plan;
      } catch (e) {
        if (!this.isCurrentPlan(epoch, orderId)) return;
        this.fail(String(e));
        return;
      }
      if (!this.isCurrentPlan(epoch, orderId)) return;
      // Solo se avisa al panel de Actividad cuando hay un plan DE VERDAD. Un
      // plan de charla llega sin tareas, y anunciarlo pintaba una tarjeta "Plan
      // propuesto · Aprobar y ejecutar" en la columna derecha por decir "Hola".
      if (this.plan?.tasks?.length) this.hooks.onActivity?.('plan', this.plan);
      if (this.plan?.needs_clarification && this.plan.questions?.length) {
        this.setPhase('clarifying');
      } else if (!this.plan?.tasks?.length) {
        // Sin tareas es una respuesta conversacional: nada que aprobar. Salvo
        // que NO sea una respuesta, sino un fallo del proveedor con la forma de
        // una: se marca para que el turno lleve su botón Reintentar (D3).
        const texto = this.plan?.understanding || '';
        // A7 (10-nov): un fallo de Directo lo dice el motor
        // (`directo_finished_v1.ok=false`), no la forma del texto.
        const directo = [...this.events].reverse().find((e) => e.kind === 'directo_finished_v1');
        this.turns.push({
          role: 'assistant',
          text: texto,
          failed: this.isProviderFailure(texto) || (directo ? eventPayload(directo).ok === false : false),
        });
        this.setPhase('chat');
        this.scrollThreadToEnd();
      } else {
        this.setPhase('awaiting-approval');
      }
      this.toggleCancel(false);
      return;
    }
    if (this.isCurrentPlan(epoch, orderId)) this.fail('La planificación superó el tiempo máximo de espera.');
  }

  private async sendAnswers(answers: { question_id: string; answer: string }[]): Promise<void> {
    if (!this.core) return;
    const epoch = this.orderEpoch;
    const orderId = this.orderId;
    this.setPhase('planning');
    this.toggleCancel(true);
    try {
      await this.core.answerOrder(orderId, answers);
      if (!this.isCurrentPlan(epoch, orderId)) return;
      await this.waitForPlan(epoch, orderId);
    } catch (e) {
      if (!this.isCurrentPlan(epoch, orderId)) return;
      this.fail(String(e));
    }
  }

  private async requestPlanChanges(): Promise<void> {
    if (!this.core || this.phase !== 'awaiting-approval' || !this.planChangeDraft.trim()) return;
    const changes = this.planChangeDraft.trim();
    const orderId = this.orderId;
    const epoch = ++this.orderEpoch;
    this.setPhase('planning');
    this.toggleCancel(true);
    try {
      await this.core.replanOrder(orderId, changes);
      if (!this.isCurrentPlan(epoch, orderId)) return;
      this.planChangeDraft = '';
      this.planEditDraft = null;
      await this.waitForPlan(epoch, orderId);
    } catch (error) {
      if (!this.isCurrentPlan(epoch, orderId)) return;
      this.setPhase('awaiting-approval');
      this.toggleCancel(false);
      notice(`No se pudo revisar el plan: ${String(error)}`, 'error');
    }
  }

  private async approve(): Promise<void> {
    if (!this.core || this.phase !== 'awaiting-approval') return;
    this.setPhase('running');
    this.cancelPending = false;
    this.cancelError = '';
    this.toggleCancel(true);

    // Punto de control ANTES de tocar nada. Si falla (la carpeta no es un
    // repositorio git, no hay git en el PATH), la orden sigue adelante: negarse
    // a trabajar por no poder guardar una foto sería peor que avisar.
    // B3: la foto se toma sobre el worktree REAL de la orden — su space, si el
    // motor le creó uno; la raiz global si no. Sin esto el checkpoint miraba
    // la raiz mientras la orden escribia en otra carpeta.
    this.checkpoint = null;
    this.checkpointRoot = '';
    this.turnCheckpoint = false;
    this.checkpointAttempted = true;
    try {
      const wt = await this.core.orderWorktree(this.orderId).catch(() => null);
      if (wt?.path) this.checkpointRoot = wt.path;
      const ck = await this.core.createCheckpoint(this.checkpointRoot);
      this.checkpoint = { sha: ck.sha, untracked: ck.untrackedCount };
    } catch (e) {
      this.checkpointError = String(e);
    }

    // Gate semántico: si el usuario declaró el observable esperado en la tarjeta
    // de aprobación, persistirlo ANTES del dispatch — el motor lo valida (JSON
    // malformado = rechazado) y el gate lo comprueba sobre archivos reales.
    // El borrador manda sobre el DOM: si un re-render recreo el textarea entre
    // la escritura y el clic, el campo visible esta vacio pero el texto sigue aqui.
    const expectedEl = this.container?.querySelector<HTMLTextAreaElement>('#order-expected');
    const expectedText = (expectedEl?.value || this.expectedDraft).trim();
    if (expectedText) {
      try {
        await this.core.setOrderExpected(this.orderId, expectedText);
        this.expectedDraft = '';
      } catch (e) {
        // Validación del motor — el usuario corrige el texto y reintenta; no
        // es un fallo de la orden, así que se queda en la tarjeta de aprobación.
        this.setPhase('awaiting-approval');
        this.toggleCancel(false);
        notice(`Observable declarado inválido: ${e}`, 'error');
        return;
      }
    }

    try {
      // SOLO despacho asíncrono. `da_order_approve` ya despacha por dentro
      // (llama a dispatchApprovedOrder de forma síncrona), así que encadenar
      // aprobar + despachar dejaba la orden fuera del estado `planned` y la
      // segunda llamada fallaba con "order must be in planned state". Además el
      // asíncrono es el que no congela la ventana mientras el modelo trabaja.
      await this.core.dispatchOrder(this.orderId);
    } catch (e) {
      this.fail(String(e));
      return;
    }
    this.startEventLoop();
  }

  /**
   * CHECKPOINT-T2: reanudación REAL de una orden 'interrupted'. El motor lee
   * el checkpoint por tarea persistido en runtime.db y continúa desde la
   * primera no completada — no es un nuevo envío del último mensaje (eso
   * reharía la planificación entera y repetiría trabajo ya hecho). El
   * seguimiento reutiliza el mismo bucle de eventos/poll que un dispatch
   * normal: el hilo de reanudación es el mismo mecanismo por dentro.
   */
  private async resumeOrder(): Promise<void> {
    if (!this.core) return;
    this.setPhase('running');
    this.cancelPending = false;
    this.cancelError = '';
    this.toggleCancel(true);
    try {
      await this.core.resumeOrder(this.orderId);
    } catch (e) {
      this.fail(String(e));
      return;
    }
    this.startEventLoop();
  }

  private async revertToCheckpoint(): Promise<void> {
    if (!this.core || !this.checkpoint) return;
    // B1d (11-nov): la vuelta de Directo pide confirmación, como los bloques
    // anteriores; revertir borra lo que esa vuelta creó.
    if (this.turnCheckpoint) {
      const checkpoint = this.checkpoint;
      const epoch = this.orderEpoch;
      const accepted = await confirmModal({
        title: 'Revertir los archivos de esta vuelta',
        paragraphs: [
          `Se restaurarán los archivos al punto de control ${checkpoint.sha}, tomado justo antes de esta vuelta.`,
          'El proyecto vuelve a como estaba antes de esta vuelta: se restauran los archivos modificados o borrados y se borran los creados en ella. Lo ignorado por .gitignore no se toca.',
        ],
        confirmLabel: 'Revertir los archivos',
        danger: true,
      });
      if (!accepted || epoch !== this.orderEpoch || this.checkpoint !== checkpoint || !this.canRestorePrior()) return;
    }
    const btn = this.container.querySelector<HTMLButtonElement>('#btn-revert');
    if (btn) {
      btn.disabled = true;
      btn.textContent = 'Revirtiendo…';
    }
    try {
      const r = await this.core.restoreCheckpoint(this.checkpoint.sha, this.checkpointRoot);
      this.checkpointMsg = checkpointRestoreMessage(r);
      MissionControlPanel.announceFilesChanged();
    } catch (e) {
      this.checkpointMsg = `No se pudo revertir: ${String(e)}`;
    }
    this.renderBody();
  }

  /**
   * B1d (11-nov): tras revertir, «Cambios», «Entorno» y «Resultados» releen
   * el proyecto (right_cards escucha este evento y llama a refreshAll).
   */
  private static announceFilesChanged(): void {
    document.dispatchEvent(new CustomEvent('devagents:workspace-changed'));
  }

  // --- Ship Flow B3 ----------------------------------------------------------
  //
  // La tarjeta enseña PRs REALES: las filas de pull_requests que escribio
  // `da_order_ship_json` tras parsear la salida de `gh`, actualizadas por el
  // poller en segundo plano. El error que llega es el stderr real de gh/git —
  // si gh no esta instalado o no hay remote, eso es lo que ve el usuario.

  /** Colores del badge segun el estado real del PR (PullRequestState). */
  private shipBadgeColor(state: string): string {
    if (state === 'merged') return 'var(--success)';
    if (state === 'failed') return 'var(--danger)';
    if (state === 'ci_running') return 'var(--warning)';
    return 'var(--accent)'; // none | ahead | open | mergeable
  }

  private shipMarkup(): string {
    if (this.shipBusy) {
      return `<div class="card"><div class="row" style="gap:8px;align-items:center">
        <span class="spinner"></span>
        <span class="card__title">Entregando como PR…</span>
      </div>
      <div class="card__subtitle" style="margin-top:6px">
        git add/commit/push y gh pr create pueden tardar unos segundos.
      </div></div>`;
    }
    if (this.shipError) {
      return `<div class="card" style="border-color:var(--danger)">
        <div class="row" style="gap:6px;align-items:center">
          <span style="color:var(--danger)">${icons.alert(14)}</span>
          <span class="card__title">No se pudo crear el PR</span>
        </div>
        <div class="card__subtitle mono" style="margin-top:6px;white-space:pre-wrap">${esc(this.shipError)}</div>
        <div class="card__subtitle" style="margin-top:4px">
          El error es el que devolvio git/gh/la API tal cual. Suele ser que gh no esta
          instalado, que falta 'gh auth login', que el remote no tiene credencial
          de API o que el workspace no tiene remote.
        </div>
        <button class="btn" id="btn-ship" title="Reintentar la entrega como PR" style="margin-top:8px">Reintentar</button>
      </div>`;
    }
    if (this.shipManual) {
      const m = this.shipManual;
      return `<div class="card" style="border-color:var(--warn,#c9a227)">
        <div class="row" style="gap:6px;align-items:center">
          <span style="color:var(--warn,#c9a227)">${icons.alert(14)}</span>
          <span class="card__title">Rama subida — PR pendiente de abrir</span>
        </div>
        <div class="card__subtitle" style="margin-top:6px">
          El push terminó: la rama <span class="mono">${esc(m.branch)}</span> ya está en el remote.
          Falta autorización de la API de Gitea para crear el PR. Usa el enlace
          /compare para abrirlo a mano:
        </div>
        <div class="card__subtitle mono" style="margin-top:6px;white-space:pre-wrap">
          <a class="pr-url" data-url="${escapeAttribute(m.url)}" href="#" style="color:var(--accent)">${esc(m.url)}</a>
        </div>
        <div class="card__subtitle" style="margin-top:6px">
          Para crear el PR desde aquí, introduce usuario y token y pulsa «Renovar credencial».
          La renovación guarda la credencial HTTPS en el administrador de credenciales de Git
          y reintenta la entrega.
        </div>
        <div class="col" style="gap:6px;margin-top:8px">
          <input class="input" id="ship-cred-user" type="text" autocomplete="off"
                 placeholder="Usuario de la forge" title="Usuario HTTPS del remote" style="font-size:12px" />
          <input class="input" id="ship-cred-pass" type="password" autocomplete="off"
                 placeholder="Token o contraseña" title="Token de acceso personal o contraseña HTTPS" style="font-size:12px" />
          <div class="row" style="gap:8px;align-items:center">
            <button class="btn" id="btn-ship-cred" title="Guarda la credencial en el administrador de Git y reintenta crear el PR">Renovar credencial</button>
            <button class="btn btn--ghost" id="btn-ship" title="Reintentar la entrega como PR">Reintentar</button>
          </div>
          <span class="subtle" id="ship-cred-status" style="font-size:11px"></span>
        </div>
      </div>`;
    }
    if (this.shipPrs.length) {
      const items = this.shipPrs
        .map((pr) => {
          const color = this.shipBadgeColor(pr.state);
          const mergeBtn =
            pr.state === 'merged' || pr.state === 'failed'
              ? ''
              : `<button class="btn btn--ghost btn-pr-merge" data-pr-id="${escapeAttribute(pr.id)}" title="Fusionar este PR en la rama principal">Merge</button>`;
          const link = pr.url
            ? `<a class="pr-url" data-url="${escapeAttribute(pr.url)}" href="#" style="color:var(--accent)">#${esc(pr.number)}</a>`
            : `<span class="mono">#${esc(pr.number)}</span>`;
          return `<div class="row" style="justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap">
            <div class="row" style="gap:8px;align-items:center">
              ${link}
              <span class="chip" style="border-color:${color};color:${color}">${esc(pr.state)}</span>
              <span class="subtle" style="font-size:11px">${esc(pr.repo)}</span>
            </div>
            ${mergeBtn}
          </div>`;
        })
        .join('');
      return `<div class="card">
        <div class="card__title">Pull request</div>
        <div class="col" style="gap:8px;margin-top:8px">${items}</div>
        <div class="card__subtitle" style="margin-top:8px">
          El estado lo refresca el poller contra GitHub en segundo plano.
        </div>
      </div>`;
    }
    return `<div class="card">
      <div class="row" style="justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
        <div class="col" style="gap:2px">
          <span class="card__title">Entregar como PR</span>
          <span class="card__subtitle">
            Sella los cambios en una rama, la sube al remote y abre el PR en su
            forge (gh en GitHub, API REST en Gitea).
          </span>
        </div>
        <button class="btn" id="btn-ship" title="Sella los cambios en una rama, la sube al remote y abre el PR">Entregar como PR</button>
      </div>
    </div>`;
  }

  /** Relee las filas de pull_requests de la orden y repinta si cambio algo. */
  private async refreshShip(): Promise<void> {
    if (!this.core || !this.orderId) return;
    try {
      const prs = await this.core.prs(this.orderId);
      if (this.orderId && this.phase === 'done') {
        this.shipPrs = prs;
        this.renderBody();
      }
    } catch {
      // La tabla puede no existir en motores viejos: se queda el boton.
    }
  }

  private async shipOrder(): Promise<void> {
    if (!this.core || !this.orderId || this.shipBusy) return;
    this.shipBusy = true;
    this.shipError = '';
    this.shipManual = null;
    this.renderBody();
    try {
      const res = await this.core.shipOrder(this.orderId);
      if (res?.error) {
        this.shipError = String(res.detail || res.error);
      } else if (res?.pr?.manual) {
        // T4-GITEA: push real hecho, PR no — la URL es el /compare honesto.
        this.shipManual = { url: String(res.pr.url), branch: String(res.pr.branch) };
      } else {
        await this.refreshShip();
      }
    } catch (e) {
      this.shipError = String(e);
    } finally {
      this.shipBusy = false;
      this.renderBody();
    }
  }

  /**
   * Guarda la credencial HTTPS de la forge en el administrador de git y
   * reintenta el ship. Es el "actualiza tus credenciales" que otras IDEs
   * piden antes de dejar probar la entrega: el secreto va por stdin a
   * `git credential approve` — la app no lo persiste.
   */
  private async saveForgeCredential(): Promise<void> {
    if (!this.core || !this.shipManual) return;
    const userEl = document.getElementById('ship-cred-user') as HTMLInputElement | null;
    const passEl = document.getElementById('ship-cred-pass') as HTMLInputElement | null;
    const statusEl = document.getElementById('ship-cred-status');
    const user = userEl?.value.trim() ?? '';
    const pass = passEl?.value ?? '';
    if (!user || !pass) {
      if (statusEl) statusEl.textContent = 'Escribe usuario y token.';
      return;
    }
    let host = '';
    try {
      host = new URL(this.shipManual.url).host;
    } catch {
      if (statusEl) statusEl.textContent = 'No se pudo leer el host del remote.';
      return;
    }
    if (statusEl) statusEl.textContent = 'Guardando credencial…';
    try {
      const res = await this.core.storeGitCredential(host, user, pass);
      if (res?.stored) {
        if (statusEl) statusEl.textContent = 'Credencial guardada. Reintentando la entrega…';
        await this.shipOrder();
      } else {
        if (statusEl) statusEl.textContent = 'El administrador de Git no confirmó la credencial. Revisa usuario y token y vuelve a pulsar «Renovar credencial».';
      }
    } catch {
      if (statusEl) statusEl.textContent = 'No se pudo renovar la credencial en el administrador de Git. Revisa usuario y token e inténtalo de nuevo; también puedes abrir el PR a mano con /compare.';
    }
  }

  private async mergePr(prId: number): Promise<void> {
    if (!this.core || !prId) return;
    try {
      const res = await this.core.mergePr(prId);
      if (res?.merged) {
        notice('PR fusionado en GitHub');
      } else if (res?.state) {
        notice(`Merge solicitado — estado real: ${res.state}`);
      }
    } catch (e) {
      this.shipError = String(e);
    }
    await this.refreshShip();
  }

  /** Sondea despacho y eventos en paralelo mientras la orden se ejecuta. */
  private startEventLoop(): void {
    this.stopEventLoop();
    this.pollHandle = window.setInterval(async () => {
      if (!this.core) return;
      try {
        await this.drainNewEvents();
        this.tickElapsed();

        const poll = await this.core.pollDispatch(this.orderId);
        if (poll.done) {
          this.stopEventLoop();
          this.toggleCancel(false);
          // B2: `poll.ok` NO es el estado real de la orden. El motor responde
          // ok del hilo de despacho aunque la orden haya fallado (el despacho
          // "terminó bien" incluso cuando commitTerminal escribió failed).
          // Medido en la orden 159: la ACTIVIDAD decía "done" mientras
          // runtime.db (orders.status='failed') y la traza terminaban en
          // order_failed cause=all_tasks_failed. La píldora del panel lateral
          // se alimenta de la fase, así que es la fase la que tiene que
          // seguir al estado TERMINAL real (la DB), no al ok del hilo.
          const terminal = await this.core.orderStatus(this.orderId).catch(() => null);
          // E5.18: status 12 = las N candidatas terminaron y la orden espera
          // la elección — NO es terminal. La tarjeta comparativa decide.
          if (terminal?.status === 12) {
            await this.loadBestOfN();
            this.setPhase('best-of-n');
            this.toggleCancel(true);
            return;
          }
          const fase = terminalOrderPhase(poll.ok, terminal?.status);
          if (fase === 'done') {
            // El turno que cierra la orden es el MENSAJE DEL AGENTE, no la
            // corriente cruda. Antes se empujaba `streamText`, que arrastraba
            // la salida del selector de herramientas al hilo: era el bloque de
            // JSON que aparecía como si fuera la respuesta.
            const resumen = this.agentSummary();
            if (resumen) this.turns.push({ role: 'assistant', text: resumen });
            this.streamText = '';
            this.setPhase('done');
          } else {
            // B2: `cancelled` (DaOrderStatus 9) no es "errores" — el mensaje
            // debe decir lo que pasó, no un genérico.
            if (fase === 'cancelled') {
              this.fail('La orden fue cancelada.');
            } else if (fase === 'audit-unavailable') {
              // AUDIT-UNAVAILABLE-P0: no es un fallo — el entregable está
              // construido, pero sin auditoría válida la entrega sigue
              // bloqueada. La fase muestra "Sin auditar" + reintento manual.
              const resumen = this.agentSummary();
              if (resumen) this.turns.push({ role: 'assistant', text: resumen });
              this.streamText = '';
              this.setPhase('audit-unavailable');
            } else {
              this.fail('La ejecución terminó con errores. Revisa la actividad del motor y el ledger.');
            }
          }
        }
      } catch (e) {
        this.stopEventLoop();
        this.fail(String(e));
      }
    }, 700);
  }

  /**
 * trae los eventos NUEVOS de la orden abierta desde `lastEventId` y
   * los publica por los tres canales (actividad, corriente, traza). Extraído
   * del cuerpo del bucle de despacho para que el camino conversacional
   * (`waitForPlan`) también lo use — antes ese camino no sondeaba NADA y el
   * tab «Salida del motor» quedaba en «Sin salida todavía» con el delta ya
   * sentado en runtime.db.
   *
   * Best-effort por diseño: si el sondeo falla, no tumba la espera de
   * planificación; el siguiente tick reintenta.
   */
  private async drainNewEvents(expectedEpoch?: number, expectedOrderId?: number): Promise<void> {
    if (!this.core) return;
    const orderId = expectedOrderId ?? this.orderId;
    const sinceId = this.lastEventId;
    try {
      const nuevos = await this.core.orderEvents(orderId, sinceId);
      if (expectedEpoch !== undefined && !this.isCurrentPlan(expectedEpoch, orderId)) return;
      // 12-nov: si mientras tanto se abrió otra sesión, estos eventos son de
      // la orden anterior: añadirlos mezclaba dos órdenes en la actividad y en
      // el grafo (visto al pasar de la orden 895 a la 891).
      if (orderId !== this.orderId || sinceId !== this.lastEventId) return;
      if (!nuevos.length) return;
      this.events.push(...nuevos);
      this.trimEventBuffers();
      this.lastEventId = Math.max(...nuevos.map((e) => Number(e.id) || 0), this.lastEventId);
      // UI-ACTION: las acciones de la orden se despachan al llegar — la cabina
      // las aplica (whitelist cliente) y reporta el ack al motor.
      for (const ev of nuevos) {
        if (ev?.kind === 'ui_action') {
          this.hooks.onUiAction?.(Number(ev.id) || 0, (ev as { payload?: unknown }).payload ?? null);
        }
        // 10-nov (propietario): el navegador «siempre que el agente lo necesite»:
        // la primera petición browser_* de la orden lo abre y lo engancha.
        if (ev?.kind === 'browser.request.v1' && orderId > 0) this.hooks.onBrowserNeeded?.(orderId);
      }
      this.watchModelHealth(nuevos);
      this.hooks.onActivity?.('events', nuevos);
      this.absorbStream(nuevos);
      this.publishEngineOutput();
      this.paintEvents();
      const note = this.container.querySelector<HTMLElement>('#planning-note');
      if (note) note.textContent = this.planningNote();
    } catch {
      // best-effort: un fallo puntual del bridge no debe romper la espera.
    }
  }

  private stopEventLoop(): void {
    if (this.pollHandle !== null) {
      window.clearInterval(this.pollHandle);
      this.pollHandle = null;
    }
  }

  private async cancel(): Promise<void> {
    if (this.phase === 'awaiting-approval' || this.phase === 'clarifying') {
      if (!this.core || !this.orderId) return;
      try {
        await this.core.cancelOrder(this.orderId);
        // CAB-003: descartar no archiva un plan pendiente; conserva el hilo.
        this.orderId = 0;
        this.reset();
      } catch (error) { notice(`No se pudo cancelar el plan: ${String(error)}`, 'error'); }
      return;
    }
    // PLAN-CANCEL: durante 'planning' el botón llama a da_plan_cancel (la
    // orden queda 'cancelled' de verdad); durante 'running' va a
    // da_order_cancel (dispatch). Antes el botón solo existía en running y la
    // planificación era incancelable hasta que el LLM respondiera.
    if (this.phase === 'planning') {
      if (!this.core || this.cancelPending) return;
      // orderId puede ser 0 en la ventana entre el clic y la respuesta de
      // submitOrder: da_plan_cancel admite 0 = "la planificación actual".
      const orderId = this.orderId;
      const epoch = this.orderEpoch;
      try {
        const result = await this.core.cancelPlan(orderId);
        if (epoch !== this.orderEpoch || this.orderId !== orderId) return;
        if (!result?.cancelled) throw new Error('El motor no confirmó la cancelación de la planificación.');
        this.cancelPending = true;
        this.cancelError = '';
        this.toggleCancel(true);
      } catch (e) {
        if (epoch !== this.orderEpoch || this.orderId !== orderId) return;
        this.cancelPending = false;
        this.cancelError = String(e);
        this.toggleCancel(true);
      }
      return;
    }
    if (this.phase === 'best-of-n') {
      // E5.18: la orden sigue abierta esperando la elección; cancelarla aquí
      // la cierra en 'cancelled' de verdad (no hay hilo de despacho en vuelo).
      if (!this.core || this.orderId <= 0) return;
      try {
        const r = await this.core.cancelOrder(this.orderId);
        if (!r?.cancelled) throw new Error('El motor no confirmó la cancelación.');
        this.fail('La orden fue cancelada.');
      } catch (e) {
        this.cancelError = String(e);
        this.toggleCancel(true);
      }
      return;
    }
    if (!this.core || this.phase !== 'running' || this.orderId <= 0 || this.cancelPending) return;
    const orderId = this.orderId;
    const epoch = this.orderEpoch;
    try {
      const result = await this.core.cancelOrder(orderId);
      if (epoch !== this.orderEpoch || this.phase !== 'running' || this.orderId !== orderId) return;
      if (!result?.cancelled) throw new Error('El motor no confirmó la solicitud de detención.');
      this.cancelPending = true;
      this.cancelError = '';
      // La solicitud no es el terminal: se mantiene el bucle que observa
      // eventos y `pollDispatch` hasta recibir la confirmación del motor.
      this.toggleCancel(true);
    } catch (e) {
      if (epoch !== this.orderEpoch || this.phase !== 'running' || this.orderId !== orderId) return;
      this.cancelPending = false;
      this.cancelError = String(e);
      this.toggleCancel(true);
    }
  }

  /**
   * Rompe el hilo y empieza de cero.
   *
   * Renovar el identificador es lo único que separa una conversación de otra
   * para el motor, y se hace SOLO aquí: así el agente nunca arrastra contexto
   * de un tema al siguiente sin que el usuario lo haya pedido.
   */
  /**
   * Carga una sesión pasada COMO CONVERSACIÓN en el panel central.
   *
   * Antes, pulsar una sesión volcaba sus mensajes en la columna de Actividad,
   * que es de solo lectura y no es donde uno espera leer una conversación. Aquí
   * se restauran los turnos en el hilo, con su scroll, y se adopta su
   * `conversation_id` para poder SEGUIR escribiendo en ella — que es lo que
   * hace cualquier IDE con historial.
   */
  public async loadSession(orderId: number, conversationId?: string): Promise<void> {
    // la época que va a usar la carga interna (se incrementa al
    // empezar). Si otra carga la sustituye mientras tanto, no se hidratan
    // las órdenes anteriores de ESTA.
    const epoch = this.sessionLoadEpoch + 1;
    await this.loadSessionCore(orderId, conversationId);
    if (this.sessionLoadEpoch === epoch && this.priorOrders.length) await this.hydratePriors(epoch);
  }

  /**
 * las órdenes del hilo, de la más antigua a la más reciente. El
   * motor ya lo expone: cada fila de `core.sessions.list` lleva su
   * `conversation_id` (modo «todas», para no perder las archivadas). Sin hilo,
   * sin método o con un fallo de lectura, la sesión se abre como antes: solo
   * la orden pedida.
   */
  private async conversationOrders(orderId: number, conversationId?: string): Promise<Array<{ id: number; status: string }>> {
    const single = [{ id: orderId, status: '' }];
    if (!conversationId || typeof this.core?.listSessions !== 'function') return single;
    try {
      const rows = await this.core.listSessions('all');
      const mine = rows
        .filter((r) => (r.conversation_id ?? '') === conversationId)
        .map((r) => ({ id: Number(r.id ?? r.order_id ?? 0), status: String(r.status_text ?? ''), at: Number(r.created_at ?? 0) }))
        .filter((r) => r.id > 0);
      if (!mine.some((r) => r.id === orderId)) mine.push({ id: orderId, status: '', at: Number.MAX_SAFE_INTEGER });
      mine.sort((a, b) => a.at - b.at || a.id - b.id);
      return mine.map(({ id, status }) => ({ id, status }));
    } catch {
      return single;
    }
  }

  /**
   * Clasifica (plan, ligero) TODAS las órdenes del hilo y trae los eventos solo
   * de las más recientes, en segundo plano. r4: antes se cortaba a las 40 últimas
   * y las más antiguas quedaban por defecto como `work`, así que una charla vieja
   * se veía como bloque de trabajo. El plan es el dato mínimo para decidir
   * charla/trabajo; los EVENTOS siguen acotados (PRIOR_EVENTS_KEEP) y el resto se
   * piden al desplegar. Todo es asíncrono y hay un único repintado al final, así
   * que un hilo largo no congela la UI.
   */
  private async hydratePriors(epoch: number): Promise<void> {
    const list = [...this.priorOrders];
    const eventsFrom = list.length - MissionControlPanel.PRIOR_EVENTS_KEEP;
    for (let i = list.length - 1; i >= 0; i--) {
      if (epoch !== this.sessionLoadEpoch) return;
      await this.hydratePrior(list[i], i >= eventsFrom, false);
    }
    if (epoch === this.sessionLoadEpoch) this.renderBody();
  }

  private async loadSessionCore(requestedOrderId: number, conversationId?: string): Promise<void> {
    let orderId = requestedOrderId;
    if (!this.core) return;
    // Defensa para otras entradas aparte de main.ts: no detener el sondeo ni
    // sustituir el estado de una orden que todavía está trabajando.
    if (!this.canOpenSession()) return;
    const epoch = ++this.sessionLoadEpoch;
    ++this.orderEpoch;
    this.stopEventLoop();
    this.errorText = '';
    // CHAT-PD-1: reabrir una conversación es entrar a otro turno. Su actividad
    // arranca con el plegado automático —terminada, plegada— en vez de heredar
    // el detalle que el usuario dejó abierto en la sesión anterior.
    this.activityOpen = null;
    this.activityFilter = '';
    this.activityShowAll = false;
    this.plan = null;
    this.events = [];
    this.lastEventId = 0;
    this.streamText = '';
    // T1-R1 (12-nov): el punto de control es de la vuelta que lo tomó. Sin
    // esto, abrir otra sesión desde la barra lateral heredaba el de la vuelta
    // anterior (otra conversación, otro proyecto) y «Revertir los archivos»
    // lo habría restaurado allí. Una sesión reabierta no tiene foto propia en
    // memoria: no se ofrece ninguna (P1-8).
    this.checkpoint = null;
    this.checkpointError = '';
    this.checkpointMsg = '';
    this.checkpointRoot = '';
    this.turnCheckpoint = false;
    this.checkpointAttempted = false;
    // Lo mismo con «Entregar como PR»: el PR abierto o el error de otra
    // sesión no se arrastran a esta.
    this.shipPrs = [];
    this.shipBusy = false;
    this.shipError = '';
    this.shipManual = null;
    this.orderId = orderId;
    this.turns = [];
    this.priorOrders = [];
    this.priorTurnCount = 0;
    this.setPhase('planning');
    try {
      // la orden en curso es la ÚLTIMA del hilo; las anteriores
      // quedan como bloques plegados encima (sus eventos, al desplegar).
      // Sin hilo que listar no hay `await` extra: la carga conserva el mismo
      // orden de llamadas al núcleo que antes de.
      const hilo = conversationId && typeof this.core.listSessions === 'function'
        ? await this.conversationOrders(orderId, conversationId)
        : [{ id: orderId, status: '' }];
      if (epoch !== this.sessionLoadEpoch) return;
      const anteriores = hilo.slice(0, -1);
      orderId = hilo[hilo.length - 1].id;
      this.orderId = orderId;
      const [msgs, events, status] = await Promise.all([
        this.core.conversationMessages(orderId),
        this.core.orderEvents(orderId, 0),
        this.core.orderStatus(orderId),
      ]);
      if (epoch !== this.sessionLoadEpoch) return;
      this.events = events;
      // una sesión histórica enorme se descarga de golpe aquí — la
      // misma cota que el drain en vivo, o abrirla reventaba igual.
      this.trimEventBuffers();
      this.lastEventId = Math.max(...events.map((e) => Number(e.id) || 0), 0);
      this.absorbStream(events);
      this.publishEngineOutput();
      if (events.length) this.hooks.onActivity?.('events', events);
      const allTurns = (msgs as Array<{
        role?: string;
        content?: string;
        order_id?: number;
      }>)
        .filter((m) => String(m.content ?? '').trim().length > 0)
        .map((m) => ({
          orderId: Number(m.order_id ?? 0),
          turn: {
            role: m.role === 'user' ? ('user' as const) : ('assistant' as const),
            text: String(m.content ?? ''),
          },
        }));
      const priorIds = new Set(anteriores.map((o) => o.id));
      this.priorOrders = anteriores.map((o) => ({
        orderId: o.id,
        status: o.status || 'done',
        // r4: sin clasificar todavía. No se asume trabajo: se pinta como
        // mensajes y `hydratePriors` lo clasifica en cuanto lee su plan.
        kind: 'unknown' as const,
        turns: allTurns.filter((t) => t.orderId === o.id).map((t) => t.turn),
        plan: null,
        events: [],
        eventsLoaded: false,
        planLoaded: false,
        planError: '',
        loading: false,
        open: false,
        checkpoint: null,
        checkpointRoot: '',
        checkpointMsg: '',
      }));
      // Primero los turnos de las órdenes anteriores (en su orden), luego los
      // de la en curso: así `priorTurnCount` es un prefijo exacto.
      const prior = this.priorOrders.flatMap((o) => o.turns);
      this.turns = [...prior, ...allTurns.filter((t) => !priorIds.has(t.orderId)).map((t) => t.turn)];
      this.priorTurnCount = prior.length;
      // Las sesiones legacy sin id no tienen vínculo histórico en la base: el
      // fallback abre un hilo nuevo y estable para sus mensajes posteriores.
      this.conversationId = conversationIdForSession({ id: orderId, conversation_id: conversationId });
      if (status.status === 2) {
        const restoredPlan = (await this.core.getPlan(orderId)) as OrderPlan;
        if (epoch !== this.sessionLoadEpoch) return;
        if (restoredPlan?.tasks?.length) {
          this.plan = restoredPlan;
          this.hooks.onActivity?.('plan', restoredPlan);
          this.setPhase('awaiting-approval');
          this.toggleCancel(false);
          this.scrollThreadToEnd();
          return;
        }
      }
      // D9: una sesión reabierta en clarifying debe volver a ofrecer las
      // preguntas; antes caía al hilo de chat y la orden se quedaba esperando
      // una respuesta que la interfaz ya no pedía.
      if (status.status === 1) {
        const restoredPlan = (await this.core.getPlan(orderId)) as OrderPlan;
        if (epoch !== this.sessionLoadEpoch) return;
        this.plan = restoredPlan;
        if (restoredPlan?.needs_clarification && restoredPlan.questions?.length) {
          this.setPhase('clarifying');
          this.scrollThreadToEnd();
          return;
        }
      }
      if (status.status === 6) {
        // A7 (10-nov): un turno conversacional que falló (Directo, charla)
        // se reabre como conversación con su fallo en línea, no como la
        // pantalla de error genérica.
        if (!workspaceRestoreDiagnostic(events)) {
          const failedPlan = (await this.core.getPlan(orderId).catch(() => null)) as OrderPlan | null;
          if (epoch !== this.sessionLoadEpoch) return;
          const reply = (failedPlan?.understanding || '').trim();
          if (failedPlan && !failedPlan.tasks?.length && reply) {
            this.plan = failedPlan;
            const live = this.turns.slice(this.priorTurnCount);
            const lastAssistant = [...live].reverse().find((t) => t.role === 'assistant');
            if (lastAssistant) lastAssistant.failed = true;
            else this.turns.push({ role: 'assistant', text: reply, failed: true });
            this.setPhase('chat');
            this.scrollThreadToEnd();
            return;
          }
        }
        this.fail(workspaceRestoreDiagnostic(events) ?? 'La orden falló en el motor. Consulta la actividad para ver la causa.');
        this.scrollThreadToEnd();
        return;
      }
      // B3: una orden terminada reabierta debe ofrecer lo mismo que al
      // terminarla en vivo — checkpoint y «Enviar a GitHub». Caer a 'chat'
      // escondía el ship hasta que la orden volviera a ejecutarse.
      if (status.status === 5) {
        this.setPhase('done');
        this.scrollThreadToEnd();
        return;
      }
      // RESUME-INTERRUPTED: el motor marcó la orden al arrancar (su hilo murió
      // con el proceso). Se enseña como lo que es —interrumpida, con la orden
      // de reanudarla— en vez de caer al chat como si no hubiera pasado nada.
      if (status.status === 10) {
        this.setPhase('interrupted');
        this.scrollThreadToEnd();
        return;
      }
      // AUDIT-UNAVAILABLE-P0: la orden reabierta cerró sin auditoría válida —
      // se enseña "Sin auditar" con su reintento, no el chat como si nada.
      if (status.status === 11) {
        // T1-R1 (12-nov): una vuelta de «DevAgents»/Directo no pasa por el
        // planificador y el motor responde «no plan available»
        // (`da_plan_get_json`, c_api.zig). Eso no es un fallo de la sesión:
        // es «sin plan». Cualquier otro error de lectura sigue fallando.
        const ownPlan = (await this.core.getPlan(orderId).catch((e: unknown) => {
          if (String(e).includes('no plan available')) return null;
          throw e;
        })) as OrderPlan | null;
        if (epoch !== this.sessionLoadEpoch) return;
        if (!ownPlan?.tasks?.length) {
          this.plan = ownPlan;
          // Remate D1 (10-nov), corregido en T1-R1: sin tareas propias, lo
          // que queda por auditar son las hijas delegadas. Si alguna quedó
          // sin auditar, la sesión reabierta queda como al terminar en vivo
          // («Reintentar auditoría», o por qué no se puede). Sin hijas
          // pendientes, se reabre como conversación.
          const deleg = MissionControlPanel.delegationRetry(events);
          const pendingChildren = !!deleg && (deleg.retryable > 0 || deleg.blocked.length > 0);
          this.setPhase(pendingChildren ? 'audit-unavailable' : 'chat');
          this.scrollThreadToEnd();
          return;
        }
        this.setPhase('audit-unavailable');
        this.scrollThreadToEnd();
        return;
      }
      // E5.18: una orden reabierta que espera la elección restaura la tarjeta
      // comparativa — la fusión sigue siendo decisión del usuario, no se
      // puede caer al chat dejando la orden en tierra de nadie.
      if (status.status === 12) {
        await this.loadBestOfN();
        if (epoch !== this.sessionLoadEpoch) return;
        this.setPhase('best-of-n');
        this.toggleCancel(true);
        this.scrollThreadToEnd();
        return;
      }
      this.setPhase('chat');
      this.scrollThreadToEnd();
    } catch (e) {
      if (epoch !== this.sessionLoadEpoch) return;
      this.fail(`No se pudo cargar la sesión #${orderId}: ${String(e)}`);
    }
  }

  /**
   * QA primerizo (10-nov): mientras el modelo trabaja, el hueco gris no decía
   * nada y un modelo local tardaba minutos sin señal. Se dice quién responde
   * y, si es local, que primero tiene que leer la petición.
   */
  private planningNote(): string {
    const started = [...(this.events ?? [])].reverse().find(ev => ev.kind === 'directo_started_v1');
    if (!started) return '';
    const p = eventPayload(started);
    const provider = String(p.provider ?? '');
    const model = String(p.model ?? '');
    if (!provider || provider === 'auto') return 'Buscando un modelo disponible…';
    const who = this.shortModel(`${provider}|${model}`);
    if (/ollama|lm ?studio|llama\.?cpp/i.test(provider))
      return `Responde ${who} en tu equipo. Un modelo local primero lee la petición: sin GPU dedicada puede tardar varios minutos.`;
    if (/^agent:/.test(provider)) return `Trabajando con ${who}…`;
    return `Responde ${who}…`;
  }

  /** Deja el hilo al final, como cualquier chat al abrirlo. */
  private scrollThreadToEnd(): void {
    window.requestAnimationFrame(() => {
      const body = this.container.querySelector<HTMLElement>('#mission-body');
      if (body) body.scrollTop = body.scrollHeight;
    });
  }

  public newConversation(): void {
    if (!this.canStartNewConversation()) {
      notice('La orden actual sigue abierta. Termínala o descarta el plan antes de iniciar otro chat.', 'info');
      return;
    }
    this.sessionLoadEpoch += 1;
    this.orderEpoch += 1;
    this.conversationId = newConversationId();
    this.turns = [];
    // un hilo nuevo empieza VACÍO, también de órdenes anteriores.
    this.priorOrders = [];
    this.priorTurnCount = 0;
    this.stopAutoCompactTimer();
    this.autoCompact = autoc.estadoInicial();
    this.reset();
  }

  /**
   * E2.11 — fork de sesión: abre una conversación NUEVA que hereda el
   * contexto de la elegida. El historial del hilo padre viaja como adjunto de
   * contexto (el planner lo recibe con la primera orden del hilo nuevo), así
   * la rama continúa donde estaba sin reescribir ni repetir peticiones. No
   * envía nada solo: el usuario revisa el adjunto y escribe la dirección.
   */
  public async forkSession(orderId: number): Promise<void> {
    if (!this.core) return;
    if (!this.canStartNewConversation()) {
      notice('Termina o descarta la orden actual antes de bifurcar una sesión.', 'info');
      return;
    }
    const msgs = (await this.core.conversationMessages(orderId).catch(() => [])) as Array<{
      role?: string;
      content?: string;
    }>;
    const texto = msgs
      .filter((m) => String(m.content ?? '').trim().length > 0)
      .map((m) => `${m.role === 'user' ? 'Usuario' : 'Agente'}: ${String(m.content ?? '')}`)
      .join('\n\n');
    this.newConversation();
    if (texto) {
      this.attachments.push({
        name: `contexto-orden-${orderId}.md`,
        content: `Historial heredado de la orden #${orderId} (fork). Úsalo como contexto del trabajo que sigue:\n\n${texto}`,
      });
      this.renderChips();
    }
    const input = this.container.querySelector<HTMLTextAreaElement>('#mission-composer-input');
    if (input) {
      input.value = `Continúa el trabajo de la orden #${orderId}: `;
      input.focus();
      input.setSelectionRange(input.value.length, input.value.length);
    }
    notice(`Fork listo: el hilo nuevo arranca con el contexto de la orden #${orderId}.`, 'info');
  }

  public reset(): void {
    // "Nueva orden" / "Seguir conversando" no borran lo hecho: la
    // orden terminada pasa a su bloque plegado del hilo.
    this.archiveCurrentOrder();
    this.pendingIssue = null;
    this.sessionLoadEpoch += 1;
    this.orderEpoch += 1;
    this.stopEventLoop();
    this.cancelPending = false;
    this.cancelError = '';
    this.orderId = 0;
    this.plan = null;
    this.expectedDraft = '';
    this.planEditDraft = null;
    this.planChangeDraft = '';
    this.events = [];
    this.lastEventId = 0;
    this.errorText = '';
    // CHAT-PD-1: la decisión de plegado es de ESTE turno. Un turno nuevo
    // vuelve al comportamiento automático en vez de heredar lo que el usuario
    // hizo con el anterior.
    this.activityOpen = null;
    this.activityFilter = '';
    this.activityShowAll = false;
    this.checkpoint = null;
    this.checkpointError = '';
    this.checkpointMsg = '';
    this.checkpointRoot = '';
    this.turnCheckpoint = false;
    this.checkpointAttempted = false;
    this.shipPrs = [];
    this.shipBusy = false;
    this.shipError = '';
    // E5.18: la tarjeta comparativa es de UNA orden — no puede quedar
    // colgada en la siguiente.
    this.bonData = null;
    this.bonBusy = false;
    this.bonError = '';
    this.bonFilesOpen = null;
    this.bonDiffHtml = null;
    this.bonDiffTitle = '';
    // Si hay conversación viva se vuelve a ella, no a la pantalla de bienvenida:
    // "volver al inicio" borraba visualmente un hilo que seguía existiendo.
    this.setPhase(this.turns.length ? 'chat' : 'idle');
    void this.refreshStatus();
  }

  // --- Utilidades de estado -------------------------------------------------

  private setPhase(p: Phase): void {
    this.phase = p;
    // E2.14 — keep-awake: con una orden viva (planificando, aclarando o
    // ejecutando) la pantalla y el equipo no se suspenden; al terminar se
    // devuelve el estado normal. Si el host no conoce el handler (build
    // viejo), la orden sigue sin enterarse — el catch solo reintenta.
    const busyAwake = p === 'planning' || p === 'clarifying' || p === 'running';
    if (busyAwake !== this.keepAwakeActive) {
      this.keepAwakeActive = busyAwake;
      void this.core?.keepAwake?.(busyAwake)?.catch(() => {
        this.keepAwakeActive = false;
      });
    }
    // D9: mientras el panel espera al usuario (plan aprobable o preguntas de
    // clarificación) la orden puede moverse por otra vía — otra IDE por MCP la
    // aprueba/cancela, o el motor la tumba (p. ej. ClarifyRoundsExhausted). Sin
    // este sondeo el panel seguía enseñando «Plan listo para aprobar» con un
    // botón que ya no vale nada.
    if (p === 'awaiting-approval' || p === 'clarifying') this.startStatusWatch();
    else this.stopStatusWatch();
    if (p === 'done') void this.refreshShip();
    // Un plan pendiente de aprobar aparece debajo del compositor: si el
    // selector estaba abierto quedaría encima tapando «Aprobar y ejecutar».
    if (p === 'awaiting-approval') this.dismissModelPicker();
    this.hooks.onActivity?.('status', p);
    this.renderBody();
    // Terminada la orden, sale el siguiente mensaje que el usuario dejó en cola.
    if (['done', 'chat', 'interrupted', 'error', 'audit-unavailable', 'idle'].includes(p) && this.sendQueue.length > 0) {
      window.setTimeout(() => this.drainSendQueue(), 0);
    }
  }

  private startStatusWatch(): void {
    this.stopStatusWatch();
    const orderId = this.orderId;
    this.statusWatchHandle = window.setInterval(() => {
      void this.reconcileOrderStatus(orderId);
    }, 2000);
  }

  private stopStatusWatch(): void {
    if (this.statusWatchHandle !== null) {
      window.clearInterval(this.statusWatchHandle);
      this.statusWatchHandle = null;
    }
  }

  /**
   * Reconcilia la fase local con el estado real de la orden. Solo actúa cuando
   * el motor dice algo distinto de lo que la fase ya refleja; los estados
   * intermedios (pending) se dejan pasar.
   */
  private async reconcileOrderStatus(orderId: number): Promise<void> {
    if (!this.core || this.orderId !== orderId) {
      this.stopStatusWatch();
      return;
    }
    const phase = this.phase;
    if (phase !== 'awaiting-approval' && phase !== 'clarifying') {
      this.stopStatusWatch();
      return;
    }
    const res = await this.core.orderStatus(orderId).catch(() => null);
    if (!res || this.orderId !== orderId) return;
    const st = Number(res.status);
    // Estados que ya coinciden con lo que la fase muestra: nada que hacer.
    if (st === 0) return; // pending: transitorio
    if (phase === 'awaiting-approval' && (st === 2 || st === 3 || st === 8)) return;
    if (phase === 'clarifying' && st === 1) return;
    if (st === 4) {
      // Aprobada y despachada por otra vía: el panel sigue la ejecución igual
      // que si el usuario hubiera pulsado «Aprobar y ejecutar».
      this.toggleCancel(true);
      this.setPhase('running');
      this.startEventLoop();
      return;
    }
    if (st === 5) {
      this.setPhase('done');
      return;
    }
    if (st === 6) {
      this.fail('La orden falló en el motor mientras esperaba tu respuesta.');
      return;
    }
    if (st === 7) {
      this.fail('La orden fue rechazada.');
      return;
    }
    if (st === 9) {
      this.fail('La orden fue cancelada.');
      return;
    }
    if (st === 11) {
      this.setPhase('audit-unavailable');
      return;
    }
    if (st === 12) {
      // Best-of-N despachado por otra vía y ya en elección: mostrar la tarjeta.
      await this.loadBestOfN();
      this.setPhase('best-of-n');
      this.toggleCancel(true);
      return;
    }
    // La orden saltó entre clarifying y planificada por otra vía (p. ej. otra
    // IDE respondió las preguntas de clarificación). Releer el plan y pintar
    // la fase que corresponde a su contenido real.
    try {
      const plan = (await this.core.getPlan(orderId)) as OrderPlan;
      if (this.orderId !== orderId) return;
      this.plan = plan;
      if (plan?.needs_clarification && plan.questions?.length) this.setPhase('clarifying');
      else if (plan?.tasks?.length) this.setPhase('awaiting-approval');
      else this.setPhase('chat');
    } catch {
      // best-effort: el siguiente tick reintenta
    }
  }

  private fail(message: string): void {
    this.stopEventLoop();
    this.errorText = message;
    this.toggleCancel(false);
    this.setPhase('error');
  }

  private isCurrentPlan(epoch: number, orderId: number): boolean {
    return epoch === this.orderEpoch && orderId === this.orderId && this.phase === 'planning';
  }

  private isPlanningEpoch(epoch: number): boolean {
    return epoch === this.orderEpoch && this.phase === 'planning';
  }

  private toggleCancel(show: boolean): void {
    const btn = this.container.querySelector<HTMLElement>('#btn-mission-cancel');
    if (!btn) return;
    btn.style.display = show ? '' : 'none';
    if (!show) return;
    const pending = this.cancelPending;
    const planning = this.phase === 'planning';
    (btn as HTMLButtonElement).disabled = pending;
    btn.textContent = pending
      ? planning ? 'Cancelando…' : 'Deteniendo…'
      : this.cancelError
        ? planning ? 'Reintentar cancelar' : 'Reintentar detener'
        : planning ? 'Cancelar' : 'Detener';
    btn.title = pending
      ? 'Solicitud enviada; esperando que el motor confirme el estado terminal.'
      : this.cancelError
        ? `No se pudo ${planning ? 'cancelar' : 'detener'}: ${this.cancelError}`
        : planning
          ? 'Cancelar la planificación en curso (la orden queda cancelada).'
          : 'Solicitar al motor que detenga la ejecución.';
  }

  /**
   * Repinta el bloque de actividad sin robarle el sitio al lector.
   *
   * Dos cosas que sí importan y antes no se hacían:
   *
   * - **El foco sobrevive al repintado.** El bloque se repinta cada vez que
   *   llegan eventos (cada 700 ms mientras trabaja). Reemplazar el `innerHTML`
   *   con el cursor dentro del filtro lo mandaba al limbo en mitad de una
   *   palabra. Se guarda y se devuelve, con la posición del cursor.
   * - **El autoscroll sólo si venías siguiendo el final.** Si el usuario ha
   *   subido a leer algo, la llegada del siguiente evento ya no lo arrastra
   *   hacia abajo. El umbral es generoso (48 px) para que «estar abajo» no
   *   dependa de un píxel.
   */
  private paintEvents(): void {
    const host = this.container.querySelector<HTMLElement>('#mission-events');
    if (!host) return;

    const body = this.container.querySelector<HTMLElement>('#mission-body');
    const siguiendoElFinal = body
      ? body.scrollHeight - body.scrollTop - body.clientHeight < 48
      : false;

    const filtroPrevio = host.querySelector<HTMLInputElement>('#activity-filter');
    const teniaFoco = !!filtroPrevio && document.activeElement === filtroPrevio;
    const cursor = filtroPrevio?.selectionStart ?? null;

    host.innerHTML = this.renderActivity();
    this.bindActivity(host);
    this.bindBotonesAbrir(host);

    if (teniaFoco) {
      const filtro = host.querySelector<HTMLInputElement>('#activity-filter');
      if (filtro) {
        filtro.focus();
        if (cursor !== null) filtro.setSelectionRange(cursor, cursor);
      }
    }
    if (siguiendoElFinal && body) {
      window.requestAnimationFrame(() => {
        body.scrollTop = body.scrollHeight;
      });
    }
    // El feed crece por ESTE camino (streaming incremental): sin re-evaluar
    // aquí, el minimapa medía solo el repintado completo y nunca llegaba a
    // aparecer durante una orden viva — medido en #435 (overflow 417 px y
    // display:none con 0 marcas).
    this.updateMinimap();
  }

  /**
   * S7: cablea el botón «Abrir» de las tarjetas de archivo escrito.
   *
   * Se enlaza aquí, después de cada repintado, porque `paintEvents` reemplaza
   * el `innerHTML` entero y con él cualquier listener anterior — el mismo
   * motivo por el que `bindActivity` vive justo encima.
   *
   * El puente (`shell.open`) solo admite http(s) o rutas locales absolutas y
   * rechaza cualquier otra cosa, así que no hay verbo de shell arbitrario que
   * pueda colarse por aquí.
   */
  private bindBotonesAbrir(host: HTMLElement): void {
    for (const btn of host.querySelectorAll<HTMLElement>('[data-abrir]')) {
      btn.addEventListener('click', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const target = btn.dataset.abrir || '';
        if (!target) return;
        void this.core?.openPath(target);
      });
    }
    // H2: se reutiliza el evento que ya usaba el panel de Cambios, para no
    // tener dos formas distintas de lanzar exactamente lo mismo.
    for (const btn of host.querySelectorAll<HTMLElement>('[data-ejecutar]')) {
      btn.addEventListener('click', (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const target = btn.dataset.ejecutar || '';
        if (!target) return;
        const status = btn.parentElement?.querySelector<HTMLElement>('[data-run-status]');
        document.dispatchEvent(new CustomEvent('devagents:run-file', {
          detail: { path: target, runner: btn.dataset.runner, report: (error: string) => {
            if (status) status.textContent = error;
          } },
        }));
      });
    }
  }

  private tickElapsed(): void {
    const el = this.container.querySelector<HTMLElement>('#mission-elapsed');
    if (el) el.innerText = this.elapsed();
  }

  private elapsed(): string {
    if (!this.startedAt) return '';
    const s = Math.floor((Date.now() - this.startedAt) / 1000);
    return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
  }

  private phaseLabel(): string {
    // Una sola tabla de etiquetas para toda la cabina (P1): aquí estaba la
    // traducción de fases y en las sesiones otra a medias. Ver
    // src/design/status_labels.ts.
    // B1e: en Directo/DevAgents el modelo responde; no hay plan que hacer.
    if (this.phase === 'planning' && this.orderIsDirect()) return 'Respondiendo';
    return statusLabel(this.phase);
  }
}

/**
 * B1 (10-nov): qué hizo «Revertir los archivos», con cifras: «N restaurados,
 * M borrados» y, si alguno no se pudo borrar (abierto por otro programa), cuáles.
 */
export function checkpointRestoreMessage(r: {
  restored?: number;
  deleted?: number;
  notDeleted?: string[];
  indexRestored?: boolean;
  indexNote?: string;
}): string {
  const restored = Number(r.restored) || 0;
  const deleted = Number(r.deleted) || 0;
  const pending = Array.isArray(r.notDeleted) ? r.notDeleted : [];
  // (tanda 1): el host devuelve también el índice de git; si no
  // pudo, lo dice y aquí se repite, nunca se da por revertido en silencio.
  const index = r.indexRestored === false
    ? ` El índice de git no se tocó: ${r.indexNote || 'el host no dio el motivo'}.`
    : '';
  if (restored === 0 && deleted === 0 && pending.length === 0) {
    return `Proyecto revertido: ya estaba como antes de la ejecución (0 restaurados, 0 borrados).${index}`;
  }
  // B1e (11-nov): visto en vivo «0 restaurados, 1 borrados»; singular y plural.
  const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
  let msg = `Proyecto revertido al estado previo a la ejecución: ${count(restored, 'restaurado', 'restaurados')}, ${count(deleted, 'borrado', 'borrados')}.`;
  if (pending.length) {
    const shown = pending.slice(0, 5).join(', ');
    msg += ` ${pending.length === 1 ? 'No se pudo borrar' : 'No se pudieron borrar'} ${pending.length}: ${shown}${pending.length > 5 ? '…' : ''}.`;
  }
  return msg + index;
}

/**
 * B1 (tarea 4): separador de la línea de hechos que el motor añade bajo la
 * respuesta (`direct_mode.FACTS_MARK`). Lo que va detrás no lo escribió el
 * modelo: son las escrituras reales de la vuelta.
 */
export const FACTS_MARK = '\n\n[DevAgents] ';
export const UNWRITTEN_NOTE = 'Esta vuelta no escribió ningún archivo.';

/** Texto del modelo y línea de hechos del motor (null si no la hay). */
export function splitFacts(text: string): { said: string; facts: string | null } {
  const at = text.lastIndexOf(FACTS_MARK);
  if (at < 0) return { said: text, facts: null };
  return { said: text.slice(0, at), facts: text.slice(at + FACTS_MARK.length).trim() };
}

/** Burbuja del asistente: Markdown del modelo y, aparte, la nota del sistema. */
export function assistantBubbleMarkup(text: string): string {
  const { said, facts } = splitFacts(text);
  if (facts === null) return renderMarkdown(text);
  const warn = facts === UNWRITTEN_NOTE;
  return `${renderMarkdown(said)}<div class="chat-facts${warn ? ' chat-facts--warn' : ''}" role="note"><span class="chat-facts__tag">DevAgents</span> <span>${esc(facts)}</span></div>`;
}

/** Último tramo de una ruta, con separadores de los dos mundos. */
function basename(p: string): string {
  return p.split(/[\\/]/).pop() || p;
}

/**
 * La primera línea con contenido de un detalle largo.
 *
 * CHAT-PD-1: fuera del bloque plegado va el HECHO de que algo falló, no su
 * volcado. El stack completo sigue estando, dentro de la actividad.
 */
function primeraLinea(texto: string): string {
  for (const linea of texto.split('\n')) {
    const t = linea.trim();
    if (t) return t;
  }
  return '';
}



/**
 * 10-nov: lectura y escritura de comodidades en localStorage que nunca lanzan.
 * Con el almacenamiento bloqueado (SecurityError) una lectura sin `try` dentro
 * de `render()` dejaba el panel entero sin pintar.
 */
function storageGet(key: string): string {
  try { return window.localStorage.getItem(key) || ''; } catch { return ''; }
}
function storageSet(key: string, value: string): void {
  try { window.localStorage.setItem(key, value); } catch { /* comodidad opcional */ }
}

/** Forma de trabajar recordada por perfil (Directo por defecto). */
// USUARIO-NUEVO B (10-nov): «devagents» = Directo que delega subtareas en
// paralelo (cada una en su worktree). Se recuerda con la misma clave.
type WorkMode = 'directo' | 'devagents' | 'orquestado' | 'colmena';
const WORK_MODE_KEY = 'devagents.workmode.v1';
function readWorkMode(): WorkMode {
  try {
    const v = localStorage.getItem(WORK_MODE_KEY);
    if (v === 'orquestado' || v === 'colmena' || v === 'directo' || v === 'devagents') return v;
  } catch { /* sin almacenamiento: vale el de por defecto */ }
  return 'directo';
}
/** (9-nov): último modelo elegido para la orden («proveedor|modelo»; vacío = Automático). */
export const ORDER_MODEL_KEY = 'devagents.orderModel.v1';
function readOrderModel(): string {
  try {
    const v = localStorage.getItem(ORDER_MODEL_KEY) || '';
    return /^[^|]+\|.+$/.test(v) ? v : '';
  } catch { return ''; }
}
function saveOrderModel(value: string): void {
  try {
    if (value) localStorage.setItem(ORDER_MODEL_KEY, value);
    else localStorage.removeItem(ORDER_MODEL_KEY);
  } catch { /* sin almacenamiento */ }
}
function saveWorkMode(mode: WorkMode): void {
  try { localStorage.setItem(WORK_MODE_KEY, mode); } catch { /* sin almacenamiento */ }
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * Saca el texto de un evento `reasoning_delta`, cuyo payload lleva la traza en
 * `reasoning`. Si viniera con otra forma se devuelve serializado: perder la
 * traza es peor que enseñarla en bruto.
 */
/**
 * Una línea legible por evento para la traza del motor.
 *
 * Antes se volcaba `payload_json`, que no existe: la columna salía SIEMPRE en
 * blanco y la traza se quedaba en una lista de nombres de evento sin ningún
 * dato. Se prefieren los campos que dicen algo (texto, descripción, modelo) y
 * solo si no hay ninguno se serializa el objeto entero.
 */
function describeEvent(ev: OrderEvent): string {
  const p = eventPayload(ev);
  for (const key of ['text', 'message', 'summary', 'description', 'content', 'error', 'reason']) {
    const v = p[key];
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  const model = typeof p.model === 'string' ? p.model : '';
  const provider = typeof p.provider === 'string' ? p.provider : '';
  if (model) return provider ? `${provider} · ${model}` : model;
  return Object.keys(p).length ? JSON.stringify(p) : String(ev.title || '');
}

/** Markup de una tarjeta de acción, sin icono (lo pone quien agrupa). */
function cardMarkup(titulo: string, detalle: string, color: string, abrir?: string, action?: ArtifactAction): string {
  // S7: `abrir` solo se pinta con una ruta LOCAL ABSOLUTA, que es lo unico que
  // `shell.open` acepta; con cualquier otra cosa el boton prometeria algo que el
  // puente va a rechazar.
  // Sin expresión regular a propósito: la versión anterior era `/^[a-zA-Z]:[\/]/`,
  // que solo casa con la barra NORMAL y por tanto nunca con una ruta de Windows —
  // el botón no llegó a pintarse ni una vez. Esta comprobación es carácter a
  // carácter la MISMA que hace el host en `shell.open` (`target[1] == ':'` y
  // `target[2]` separador), así que la interfaz solo ofrece lo que el puente acepta.
  const abrible =
    !!abrir && abrir.length > 2 && abrir[1] === ':' && (abrir[2] === '\\' || abrir[2] === '/');
  // H2: un programa de consola generado por el agente no se podia USAR desde
  // aqui. «Abrir» se lo pasa al sistema (un .py acaba en el editor de turno) y
  // el executor del motor lo corre sin nadie al otro lado del teclado: por eso
  // una calculadora interactiva moria en el primer `input()`. Este boton lo
  // lanza en una consola de verdad, donde el usuario puede TECLEAR.
  const nombre = abrir?.split(/[\\/]/).pop() || '';
  const javascript = /\.(?:js|mjs)$/i.test(nombre);
  const runner = javascript ? action?.runner ?? null : runnerFor(nombre);
  const ejecutable = abrible && runner !== null;
  const destinoAbrir = action?.page ?? abrir;
  const esPagina = Boolean(action?.page) || /\.html?$/i.test(nombre);
  return `<div class="card row" style="gap:10px;align-items:flex-start;padding:10px 12px">
     <div class="col grow" style="gap:2px;min-width:0">
       <span style="font-size:13px;font-weight:550;color:${color}">${esc(titulo)}</span>
       ${detalle ? `<span class="subtle" style="font-size:11px;word-break:break-word">${esc(detalle)}</span>` : ''}
     </div>
     ${ejecutable ? `<button class="btn ghost" data-ejecutar="${escapeAttribute(abrir!)}" data-runner="${escapeAttribute(runner!)}" title="Ejecutar en una consola donde puedes escribir" style="flex:0 0 auto">Ejecutar</button><span data-run-status role="status" class="subtle"></span>` : ''}
     ${abrible ? `<button class="btn ghost" data-abrir="${escapeAttribute(destinoAbrir!)}" title="${esPagina ? 'Abrir la página HTML generada' : 'Abrir con la aplicacion del sistema'}" style="flex:0 0 auto">${esPagina ? 'Ver página' : 'Abrir'}</button>` : ''}
   </div>`;
}

function extractReasoning(ev: OrderEvent): string {
  const p = eventPayload(ev);
  if (typeof p.reasoning === 'string') return p.reasoning;
  if (typeof p.content === 'string') return p.content;
  if (typeof p.text === 'string') return p.text;
  return Object.keys(p).length ? JSON.stringify(p) : '';
}

/** Basta con que sea único dentro de este equipo: la clave la guarda el motor. */
function newConversationId(): string {
  return `conv-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}
