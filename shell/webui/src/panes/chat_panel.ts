import { escapeText as esc, escapeAttribute } from '../design/html';
import { icons } from '../design/icons';
import { departmentLabel } from '../design/status_labels';
import { OrderEvent, eventPayload } from '../bridge/core_api';
import { Timeline } from '../components/timeline';
import { artifactAction } from '../file_runtime';
import { consolasDeWorkers } from '../chat_activity';

/**
 * Panel lateral del agente.
 *
 * Cabecera con estado en vivo, cuerpo con la conversación + la actividad
 * real del motor (OrderEvent via appendEvents) + la tarjeta de plan
 * pendiente de aprobación, y un compositor inferior. Nada de esto usa
 * colores hex ni emojis: todo son clases de `stylesheet.ts` y tokens.
 */

export type ChatMode = 'agent' | 'chat' | 'write';

export interface ChatMessage {
  id: string;
  sender: string;
  role: 'user' | 'assistant' | 'system';
  content: string;
  timestamp: number;
  bashCard?: {
    title: string;
    command: string;
    output: string;
  };
}

export interface ChatAttachment {
  name: string;
  type: string;
  content: string;
}

export type ChatStatusKind = 'idle' | 'working' | 'error';
type SendHandler = (text: string, mode: string, attachments?: ChatAttachment[]) => void;



/**
 * Intérprete con el que se lanza un archivo, o null si no se sabe ejecutar.
 *
 * Deliberadamente corto: solo lo que este proyecto produce y se puede lanzar
 * sin compilar. Un `.zig` o un `.cpp` necesitan build, y ofrecer un botón que
 * falla es peor que no ofrecerlo.
 */
export { runnerFor } from '../file_runtime';

function statusColor(kind: ChatStatusKind): string {
  if (kind === 'working') return 'var(--accent)';
  if (kind === 'error') return 'var(--danger)';
  return 'var(--fg-subtle)';
}

/** Una tarea larga se consulta en el centro; la columna de actividad solo orienta. */
function compactTaskLabel(value: unknown): string {
  const text = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (!text) return 'Tarea sin descripción';
  const firstSentence = text.match(/^(.{1,96}?)(?:[.!?](?:\s|$)|$)/)?.[1] ?? text;
  return firstSentence.length > 96 ? `${firstSentence.slice(0, 93)}…` : firstSentence;
}

export class ChatPanel {
  private container: HTMLElement;
  private conversationControl?: unknown;

  private mode: ChatMode = 'agent';
  private messages: ChatMessage[] = [];
  private currentPlan: unknown = null;
  private statusKind: ChatStatusKind = 'idle';

  private startTimeMs: number | null = null;
  private timerInterval: ReturnType<typeof setInterval> | null = null;

  private onApproveHandler?: () => void;
  private onCancelHandler?: () => void;

  private timeline!: Timeline;

  private elBody!: HTMLElement;
  private elEmpty!: HTMLElement;
  private elMessages!: HTMLElement;
  private elActivity!: HTMLElement;
  private elPlan!: HTMLElement;
  private elStatusDot!: HTMLElement;
  private elStatusText!: HTMLElement;
  private elTimer!: HTMLElement;
  private elTimerText!: HTMLElement;

  constructor(container: HTMLElement, conversationControl?: unknown) {
    this.container = container;
    this.conversationControl = conversationControl;
    this.render();
  }

  // -------------------------------------------------------------- Modo ---

  public setMode(mode: ChatMode): void {
    this.mode = mode;
  }

  public getMode(): ChatMode {
    return this.mode;
  }

  // ----------------------------------------------------------- API pub --

  public setOnApprove(cb: () => void): void {
    this.onApproveHandler = cb;
  }

  public setOnCancel(cb: () => void): void {
    this.onCancelHandler = cb;
  }

  public addMessage(msg: ChatMessage): void {
    this.messages.push(msg);
    this.renderMessages();
    this.scrollToBottom();
  }

  public startTimer(): void {
    this.startTimeMs = Date.now();
    if (this.timerInterval) clearInterval(this.timerInterval);
    this.elTimer.style.display = 'inline-flex';
    this.showComposer(true);
    this.setStatus('Trabajando...', 'working');
    this.updateTimerText();
    this.timerInterval = setInterval(() => this.updateTimerText(), 1000);
  }

  public stopTimer(): void {
    if (this.timerInterval) {
      clearInterval(this.timerInterval);
      this.timerInterval = null;
    }
    this.elTimer.style.display = 'none';
    if (this.statusKind === 'working') this.setStatus('Listo', 'idle');
  }

  public clear(): void {
    this.messages = [];
    this.currentPlan = null;
    this.timeline.clear();
    this.changed.clear();
    this.artifactEvents = [];
    this.workers.clear();
    this.workerStatus.clear();
    this.workerOutputEvents = [];
    this.renderChanges();
    this.renderWorkers();
    this.renderConsoles();
    this.elActivity.style.display = 'none';
    this.elEmpty.style.display = 'flex';
    this.showComposer(false);
    this.renderMessages();
    this.renderPlan();
  }

  /** Pill de estado de la cabecera. */
  public setStatus(text: string, kind: ChatStatusKind): void {
    this.statusKind = kind;
    this.elStatusText.textContent = text;
    this.elStatusDot.style.background = statusColor(kind);
  }

  /**
   * El compositor de seguimiento solo tiene sentido con una orden viva; en la
   * pantalla de inicio duplicaría el compositor del centro de mando.
   */
  public showComposer(visible: boolean): void {
    const el = this.container.querySelector<HTMLElement>('#chat-composer');
    if (el) el.style.display = visible ? 'flex' : 'none';
  }

  /** Vuelca eventos reales del motor (core.order.events) en la línea de tiempo. */
  /** Archivos tocados, por ruta, con la última acción registrada. */
  private changed = new Map<string, string>();
  /** Eventos de archivo para clasificar el runtime sin adivinar por extensión. */
  private artifactEvents: OrderEvent[] = [];
  /** Modelo asignado a cada tarea del plan. */
  private workers = new Map<string, string>();
  /** Estado vivo por tarea (trabajando/hecho/falló/bloqueada) — la respuesta a
   *  «ver a los agentes trabajar» sin una vista de procesos. Solo lo escriben
   *  los eventos de ciclo de vida; `task_audit` es un asiento del ledger con
   *  id numérico, no un worker, así que no genera fila. */
  private workerStatus = new Map<string, 'running' | 'done' | 'failed' | 'blocked'>();
  /** `worker_output` crudos del turno, para las consolas paralelas. */
  private workerOutputEvents: OrderEvent[] = [];
  /** tope de eventos worker_output retenidos (la consola pinta 64 KB
   *  por worker; más allá solo se infla el heap). */
  private static readonly WORKER_OUTPUT_CAP = 2000;

  public appendEvents(events: OrderEvent[]): void {
    if (!events || events.length === 0) return;
    // Medir ANTES de mutar el DOM: una vez añadidas las filas, scrollHeight ya
    // creció y el "¿estaba el usuario abajo?" sería siempre falso — con cada
    // lote de eventos (~700 ms) el panel arrastraba la vista al final y no se
    // podía subir a leer la traza mientras la orden trabajaba.
    const siguiendoElFinal =
      this.elBody.scrollHeight - this.elBody.scrollTop - this.elBody.clientHeight < 48;
    events.forEach((ev) => {
      this.timeline.addEvent(ev);
      if (String(ev.kind ?? '') === 'file_written') this.artifactEvents.push(ev);
      this.harvest(ev);
    });
    this.elActivity.style.display = '';
    // El estado vacío se apagaba solo al haber MENSAJES, así que el panel podía
    // decir "Sin actividad todavía" justo encima de la lista de cambios y de
    // los modelos trabajando. Con actividad a la vista, sobra.
    this.elEmpty.style.display = 'none';
    this.renderChanges();
    this.renderWorkers();
    this.renderConsoles();
    if (siguiendoElFinal) this.scrollToBottom();
  }

  /**
   * Saca de cada evento lo que de verdad le interesa al usuario: qué archivo se
   * tocó y qué modelo lo hizo.
   *
   * El payload del motor no tiene una forma fija (cada tipo de evento escribe
   * su propio JSON), así que se buscan varios alias en vez de asumir un
   * esquema. Si un evento no encaja, simplemente no aporta nada: sigue estando
   * en la traza de abajo.
   */
  private harvest(ev: OrderEvent): void {
    const payload = eventPayload(ev);
    const kind = String(ev.kind ?? '');

    // Los alias son los que el motor emite DE VERDAD, comprobados sobre los
    // 1257 eventos guardados en runtime.db: `file_path` y `artifact_name` en
    // `file_written`, y `file` en `shell_command`. Los nombres que había aquí
    // (`path`, `artifact`, `output_path`) no aparecen en ninguno, así que el
    // panel de Cambios no se llenaba nunca.
    const path = String(
      payload.file_path ?? payload.path ?? payload.file ?? payload.artifact_name ?? payload.artifact ?? payload.output_path ?? ''
    );
    if (path && kind === 'file_written') this.changed.set(path, kind);

    // El motor nombra el modelo en `model` y el proveedor aparte, en `provider`
    // (visto en el payload real de `task_started`). Enseñar solo "gpt-5" cuando
    // hay tres proveedores que lo sirven no basta para saber quién trabajó.
    const task = String(payload.task_id ?? payload.task ?? payload.worker_id ?? '');
    const model = String(payload.model ?? payload.model_used ?? payload.assigned_model ?? payload.model_id ?? '');
    const provider = String(payload.provider ?? '');
    // task_audit es un asiento del ledger con id numérico, no otro worker.
    if (task && model && kind !== 'task_audit') {
      const previous = this.workers.get(task);
      const label = model === 'deterministic' ? 'Ejecutor local'
        : model === 'not-run' ? 'Sin ejecutar'
        : provider ? `${provider} · ${model}` : previous?.endsWith(` · ${model}`) ? previous : model;
      this.workers.set(task, label);
    }
    // Estado vivo por tarea: la columna responde «¿quién trabaja y en qué va?»
    // — lo que antes se quería ver de los subagentes sin tener una vista de
    // procesos. Todo sale de los mismos OrderEvent reales; sin evento no hay
    // fila. `task_audit` queda fuera a propósito (asiento del ledger, no
    // worker): si entrara inflaría la lista con un id numérico sin modelo.
    const statusOf: Record<string, 'running' | 'done' | 'failed' | 'blocked'> = {
      task_started: 'running',
      task_done: 'done',
      task_failed: 'failed',
      task_blocked: 'blocked',
      // AUDIT-UNAVAILABLE-P0: el auditor no entregó veredicto usable — la tarea
      // queda bloqueada, no trabajando para siempre ni fallida.
      task_audit_unavailable_v1: 'blocked',
    };
    const st = statusOf[kind];
    if (task && st) (this.workerStatus ??= new Map()).set(task, st);

    // La salida cruda de cada worker se conserva para las consolas paralelas.
    // Solo se guarda el evento; el agrupado lo hace `consolasDeWorkers`.
    // cota — la consola renderiza como mucho 64 KB por worker, así que
    // retener cada evento para siempre solo inflaba el heap del renderer
    // hasta dejar la ventana en blanco en órdenes largas.
    if (kind === 'worker_output') {
      this.workerOutputEvents.push(ev);
      if (this.workerOutputEvents.length > ChatPanel.WORKER_OUTPUT_CAP) {
        this.workerOutputEvents.splice(0, this.workerOutputEvents.length - ChatPanel.WORKER_OUTPUT_CAP);
      }
    }
  }

  /**
   * Consolas paralelas por worker/tarea (F3). La lista de "Ejecución por
   * tarea" dice QUIÉN trabaja; esta sección enseña QUÉ escribe cada uno: el
   * `worker_output` agrupado por `task_id`/`worker_id`/`stream`.
   */
  private renderConsoles(): void {
    const host = this.container.querySelector<HTMLElement>('#chat-consoles-list');
    const box = this.container.querySelector<HTMLElement>('#chat-consoles');
    if (!host || !box) return;
    const consolas = consolasDeWorkers(this.workerOutputEvents);
    if (!consolas.length) {
      box.style.display = 'none';
      return;
    }
    box.style.display = 'flex';
    host.innerHTML = consolas
      .map((c) => {
        // Abierta mientras la tarea sigue viva; plegada cuando terminó — la
        // salida queda a un clic sin ocupar la pantalla entera.
        const viva = this.workerStatus.get(c.id) === 'running' || !this.workerStatus.has(c.id);
        const etiqueta = c.nombre === c.stream ? c.nombre : `${c.nombre} · ${c.stream}`;
        return `<details class="reasoning" ${viva ? 'open' : ''}>
          <summary class="reasoning__summary" title="Salida de ${escapeAttribute(c.nombre)}">${esc(etiqueta)} · ${c.trozos} trozo${c.trozos === 1 ? '' : 's'}${c.capado ? ' · truncado' : ''}</summary>
          <pre class="code-surface" style="margin:4px 0 0;padding:8px 10px;max-height:240px;overflow:auto;white-space:pre-wrap;word-break:break-word;font-size:11px">${esc(c.texto)}</pre>
        </details>`;
      })
      .join('');
  }

  private renderChanges(): void {
    const host = this.container.querySelector<HTMLElement>('#chat-changes-list');
    const box = this.container.querySelector<HTMLElement>('#chat-changes');
    if (!host || !box) return;
    if (!this.changed.size) {
      box.style.display = 'none';
      return;
    }
    box.style.display = 'flex';
    host.innerHTML = [...this.changed.entries()]
      .map(([p, kind]) => {
        const name = p.split(/[\\/]/).pop() || p;
        const dir = p.slice(0, p.length - name.length).replace(/[\\/]$/, '');
        const action = artifactAction(this.artifactEvents, p);
        const previewPage = /\.html?$/i.test(p) ? p : action.page;
        // Pulsar abre el archivo en el editor; la página comprobada conserva
        // una acción propia de navegador, y el botón de ejecutar lo lanza en
        // la terminal integrada, que vive FUERA del executor y por tanto no se
        // lleva por delante lo que arranque.
        const shortDir = dir.split(/[\\/]/).filter(Boolean).slice(-2).join('/');
        return `<div class="list-item" data-open="${escapeAttribute(p)}" title="Abrir ${escapeAttribute(p)}" style="align-items:center">
          <div class="col grow" style="min-width:0;gap:3px">
            <span class="list-item__label" style="width:100%;color:var(--text)">${esc(name)}</span>
            <span class="subtle" style="font-size:10px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="${escapeAttribute(dir)}">${esc(shortDir)}</span>
          </div>
          <span class="badge badge--success" style="flex-shrink:0">${esc(kind === 'file_written' ? 'Escrito' : kind)}</span>
          ${
            previewPage
              ? `<button class="icon-btn" data-preview="${escapeAttribute(previewPage)}" title="Vista previa y señalar un elemento" aria-label="Vista previa y señalar un elemento">${icons.external(12)}</button>`
              : ''
          }
          ${
            action.runner !== null
              ? `<button class="icon-btn" data-run="${escapeAttribute(p)}" data-runner="${escapeAttribute(action.runner)}" title="Ejecutar ${escapeAttribute(name)} en la terminal">${icons.play(12)}</button><span data-run-status role="status" class="subtle"></span>`
              : ''
          }
        </div>`;
      })
      .join('');

    host.querySelectorAll<HTMLElement>('[data-open]').forEach((el) => {
      el.addEventListener('click', (ev) => {
        // El botón de ejecutar vive dentro de la fila: no debe abrir además.
        if ((ev.target as HTMLElement).closest('[data-run], [data-preview]')) return;
        document.dispatchEvent(
          new CustomEvent('devagents:open-file', { detail: el.dataset.open })
        );
      });
    });
    host.querySelectorAll<HTMLElement>('[data-run]').forEach((el) => {
      el.addEventListener('click', (ev) => {
        ev.stopPropagation();
        document.dispatchEvent(
          new CustomEvent('devagents:run-file', { detail: { path: el.dataset.run, runner: el.dataset.runner, report: (error: string) => {
            const status = el.parentElement?.querySelector<HTMLElement>('[data-run-status]');
            if (status) status.textContent = error;
          } } })
        );
      });
    });
    host.querySelectorAll<HTMLElement>('[data-preview]').forEach((el) => {
      el.addEventListener('click', (ev) => {
        ev.stopPropagation();
        const target = el.dataset.preview || '';
        if (target) document.dispatchEvent(new CustomEvent('devagents:preview-artifact', { detail: { path: target } }));
      });
    });
  }

  private renderWorkers(): void {
    const host = this.container.querySelector<HTMLElement>('#chat-workers-list');
    const box = this.container.querySelector<HTMLElement>('#chat-workers');
    if (!host || !box) return;
    if (!this.workers.size) {
      box.style.display = 'none';
      return;
    }
    box.style.display = 'flex';
    const statusBadge: Record<string, { text: string; cls: string }> = {
      running: { text: 'trabajando', cls: 'badge--accent' },
      done: { text: 'hecho', cls: 'badge--success' },
      failed: { text: 'falló', cls: 'badge--danger' },
      blocked: { text: 'bloqueada', cls: 'badge--warning' },
    };
    host.innerHTML = [...this.workers.entries()]
      .map(([task, model]) => {
        const st = statusBadge[this.workerStatus.get(task) ?? 'running'] ?? statusBadge.running;
        return `<div class="list-item" style="cursor:default">
          <span class="badge badge--accent">${esc(task)}</span>
          <span class="list-item__label mono" style="font-size:11px;min-width:0;overflow:hidden;text-overflow:ellipsis">${esc(model || '—')}</span>
          <span class="badge ${st.cls}" style="flex-shrink:0">${esc(st.text)}</span>
        </div>`;
      })
      .join('');
  }

  /** Muestra el plan propuesto por el motor con acciones de aprobación. */
  public setPlan(plan: unknown): void {
    this.currentPlan = plan;
    this.renderPlan();
    this.scrollToBottom();
  }

  // ------------------------------------------------------------ Render --

  private render(): void {
    this.container.innerHTML = `
      <div class="col" style="height:100%; min-height:0;">
        <div class="row" id="chat-header" style="flex:0 0 auto; border-bottom:1px solid var(--border);">
          <div class="row" id="chat-header-info" style="gap:10px;">
            <span class="section-label">Actividad</span>
            <span class="pill" id="chat-status-pill">
              <span class="pill__dot" id="chat-status-dot"></span>
              <span id="chat-status-text">Inactivo</span>
            </span>
            <span class="row" id="chat-timer" style="display:none; gap:6px;">
              <span class="spinner"></span>
              <span class="mono subtle" id="chat-timer-text" style="font-size:11px;">00:00</span>
            </span>
          </div>
          <div class="row" style="gap:4px;">
            <!-- E5.22: ventana aislada con esta conversación; main añade el
                 order_id vigente y traduce el gesto al puente window.open. -->
            <button class="icon-btn" id="chat-btn-popout" title="Abrir la conversación en una ventana nueva" aria-label="Abrir la conversación en una ventana nueva">&#10697;</button>
            <button class="icon-btn" id="chat-btn-collapse" title="Plegar panel de actividad">${icons.chevronRight()}</button>
            <button class="icon-btn" id="chat-btn-clear" title="Limpiar conversación">${icons.trash()}</button>
          </div>
        </div>

        <div class="col grow" id="chat-content" style="min-height:0;">
          <div class="col grow scroll-y" id="chat-body" style="padding:14px; gap:14px;">
            <div id="chat-empty" class="empty-state">
              <span class="empty-state__title">Sin actividad todavía</span>
              <span>Aquí aparecerán el plan, el razonamiento y los comandos<br/>en cuanto lances una orden desde el compositor central.</span>
            </div>

            <div id="chat-messages" class="col" style="display:none; gap:14px;"></div>

            <!-- CAMBIOS. Lo que el fork y Astra ponen en esta columna: qué
                 archivos ha tocado el agente y qué modelo trabajó en cada
                 tarea. Va ARRIBA porque es lo que se mira; la línea de
                 eventos crudos queda debajo, plegada. -->
            <div id="chat-changes" class="col" style="display:none; gap:8px;">
              <span class="section-label">Cambios</span>
              <div id="chat-changes-list" class="col" style="gap:2px;"></div>
            </div>

            <div id="chat-workers" class="col" style="display:none; gap:8px;">
              <span class="section-label">Ejecución por tarea</span>
              <div id="chat-workers-list" class="col" style="gap:2px;"></div>
            </div>

            <!-- CONSOLAS POR WORKER. El motor emite worker_output por trozo
                 en vivo (superagent.zig) y lo vuelca al final; aquí se reagrupa
                 por tarea/worker para leer cada corriente por separado. Sin
                 esto F8 no se ve: doce workers producían una traza única
                 mezclada. -->
            <div id="chat-consoles" class="col" style="display:none; gap:8px;">
              <span class="section-label">Consolas de workers</span>
              <div id="chat-consoles-list" class="col" style="gap:4px;"></div>
            </div>

            <details id="chat-activity" class="reasoning" style="display:none">
              <summary class="reasoning__summary">Traza del motor</summary>
              <div class="reasoning__body" style="max-height:none;padding:8px 10px">
                <div id="chat-timeline-mount"></div>
              </div>
            </details>

            <div id="chat-plan" style="display:none;"></div>
          </div>

          <!-- Aquí vivía un SEGUNDO compositor, con adjuntos incluidos, resto de
               la maqueta original. Enviaba al mismo ciclo que el central, así
               que había dos cajas de chat compitiendo y la buena (la de
               adjuntar) era la escondida. Se retiró: este panel es de solo
               lectura y muestra plan, razonamiento y comandos, que es
               exactamente lo que promete su propio estado vacío. Los adjuntos
               se movieron al compositor central. -->
        </div>
      </div>
    `;

    this.elBody = this.container.querySelector('#chat-body') as HTMLElement;
    this.elEmpty = this.container.querySelector('#chat-empty') as HTMLElement;
    this.elMessages = this.container.querySelector('#chat-messages') as HTMLElement;
    this.elActivity = this.container.querySelector('#chat-activity') as HTMLElement;
    this.elPlan = this.container.querySelector('#chat-plan') as HTMLElement;
    this.elStatusDot = this.container.querySelector('#chat-status-dot') as HTMLElement;
    this.elStatusText = this.container.querySelector('#chat-status-text') as HTMLElement;
    this.elTimer = this.container.querySelector('#chat-timer') as HTMLElement;
    this.elTimerText = this.container.querySelector('#chat-timer-text') as HTMLElement;
    const timelineMount = this.container.querySelector('#chat-timeline-mount') as HTMLElement;
    this.timeline = new Timeline(timelineMount);

    this.setStatus('Inactivo', 'idle');
    this.bindEvents();
  }

  private bindEvents(): void {
    this.container.querySelector('#chat-btn-clear')?.addEventListener('click', () => this.clear());
    this.container.querySelector('#chat-btn-popout')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('devagents:open-window', { detail: { vista: 'conversacion' } }));
    });
  }

  private renderMessages(): void {
    const hasMessages = this.messages.length > 0;
    this.elEmpty.style.display = hasMessages ? 'none' : 'flex';
    this.elMessages.style.display = hasMessages ? 'flex' : 'none';

    if (!hasMessages) {
      this.elMessages.innerHTML = '';
      return;
    }

    this.elMessages.innerHTML = this.messages.map((msg) => this.renderMessage(msg)).join('');

    this.elMessages.querySelectorAll<HTMLElement>('[data-bash-toggle]').forEach((header) => {
      header.addEventListener('click', () => {
        const body = header.nextElementSibling as HTMLElement | null;
        const chevron = header.querySelector('[data-chevron]') as HTMLElement | null;
        if (!body) return;
        const isOpen = body.style.display !== 'none';
        body.style.display = isOpen ? 'none' : 'block';
        if (chevron) chevron.innerHTML = isOpen ? icons.chevronRight() : icons.chevronDown();
      });
    });
  }

  private renderMessage(msg: ChatMessage): string {
    const time = new Date(msg.timestamp).toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit' });
    const bashCardHtml = msg.bashCard ? this.renderBashCard(msg.bashCard) : '';

    if (msg.role === 'system') {
      return `
        <div style="align-self:center; font-size:11px; color:var(--fg-subtle); text-align:center; max-width:90%;">
          ${esc(msg.content)}
        </div>
      `;
    }

    if (msg.role === 'user') {
      return `
        <div style="align-self:flex-end; max-width:88%; background:var(--surface-2); border-radius:var(--radius-md); padding:9px 13px;">
          <div style="font-size:13px; line-height:1.55; color:var(--fg); white-space:pre-wrap; word-break:break-word;">${esc(msg.content)}</div>
          ${bashCardHtml}
          <div style="font-size:10px; color:var(--fg-subtle); text-align:right; margin-top:4px;">${esc(time)}</div>
        </div>
      `;
    }

    return `
      <div class="col" style="gap:4px; width:100%;">
        <div class="row" style="justify-content:space-between;">
          <span class="section-label">${esc(msg.sender)}</span>
          <span style="font-size:10px; color:var(--fg-subtle);">${esc(time)}</span>
        </div>
        <div style="font-size:13px; line-height:1.6; color:var(--fg); white-space:pre-wrap; word-break:break-word;">${esc(msg.content)}</div>
        ${bashCardHtml}
      </div>
    `;
  }

  private renderBashCard(card: { title: string; command: string; output: string }): string {
    return `
      <div style="margin-top:8px; border:1px solid var(--border); border-radius:var(--radius-sm); overflow:hidden;">
        <div data-bash-toggle class="row" style="justify-content:space-between; gap:8px; padding:6px 10px; background:var(--surface-2); cursor:pointer;">
          <span class="row" style="gap:6px; font-size:12px; color:var(--fg); font-weight:500;">
            <span style="display:flex; color:var(--fg-subtle);">${icons.terminal(14)}</span>
            ${esc(card.title)}
          </span>
          <span data-chevron style="display:flex; color:var(--fg-subtle);">${icons.chevronRight(14)}</span>
        </div>
        <div style="display:none;">
          <pre class="code-surface" style="margin:0; padding:10px; white-space:pre-wrap; word-break:break-word;">$ ${esc(card.command)}
${esc(card.output)}</pre>
        </div>
      </div>
    `;
  }

  private renderPlan(): void {
    if (!this.currentPlan) {
      this.elPlan.style.display = 'none';
      this.elPlan.innerHTML = '';
      return;
    }

    const plan = this.currentPlan as Record<string, unknown>;
    const title = typeof plan?.title === 'string' ? (plan.title as string) : 'Plan propuesto';
    const summary = typeof plan?.summary === 'string' ? (plan.summary as string) : '';
    const rawSteps = Array.isArray(plan?.steps) ? (plan.steps as unknown[]) : Array.isArray(plan?.tasks) ? (plan.tasks as unknown[]) : [];
    const steps = rawSteps.map((step, index) => {
      if (typeof step === 'string') return { label: compactTaskLabel(step), detail: step, meta: '' };
      if (step && typeof step === 'object') {
        const o = step as Record<string, unknown>;
        const detail = String(o.description ?? o.title ?? o.name ?? JSON.stringify(o));
        const outputField = Array.isArray(o.contract_fields)
          ? o.contract_fields.find((field: any) => ['filename', 'file', 'archivo'].includes(field?.name) && typeof field?.value === 'string')
          : undefined;
        const label = compactTaskLabel(o.title ?? o.name ?? outputField?.value ?? detail);
        const department = departmentLabel(String(o.department ?? o.task_type ?? ''));
        const dependencies = Array.isArray(o.depends_on)
          ? (o.depends_on as unknown[]).map(String).filter(Boolean).join(', ')
          : '';
        return {
          label,
          detail,
          meta: [department, dependencies ? `depende de ${dependencies}` : ''].filter(Boolean).join(' · '),
        };
      }
      const detail = String(step);
      return { label: compactTaskLabel(detail), detail, meta: `tarea ${index + 1}` };
    });

    // Aquí había un "Cancelar" y un "Aprobar y ejecutar" que NO HACÍAN NADA:
    // `setOnApprove`/`setOnCancel` no se llamaban desde ningún sitio, así que
    // los handlers eran siempre undefined. Y la tarjeta no se limpiaba nunca,
    // de modo que seguía ofreciendo aprobar una orden ya ejecutada. Este panel
    // es de SOLO LECTURA por diseño (el único sitio donde se decide es el
    // centro), así que la tarjeta se queda como resumen y lo que cambia es la
    // etiqueta de estado.
    const estado = this.planStatusBadge();
    this.elPlan.style.display = 'block';
    this.elPlan.innerHTML = `
      <div class="card">
        <div class="row" style="justify-content:space-between; margin-bottom:6px;">
          <span class="card__title">${esc(title)}</span>
          <span class="badge ${estado.cls}">${esc(estado.text)}</span>
        </div>
        ${summary ? `<div class="card__subtitle" style="margin-bottom:8px;">${esc(summary)}</div>` : ''}
        ${steps.length > 0 ? `
          <ol class="plan-activity-summary" style="margin:0 0 4px 18px; padding:0; display:flex; flex-direction:column; gap:6px;">
            ${steps.map((step) => `<li style="font-size:12px; color:var(--fg-muted);">
              <span>${esc(step.label)}</span>
              ${step.meta ? `<span class="subtle" style="display:block;font-size:10px;margin-top:2px">${esc(step.meta)}</span>` : ''}
              <details style="margin-top:3px"><summary style="cursor:pointer;font-size:11px;color:var(--accent)">Ver detalle</summary><div style="padding:5px 0 2px;white-space:pre-wrap;word-break:break-word">${esc(step.detail)}</div></details>
            </li>`).join('')}
          </ol>
        ` : ''}
        ${
          estado.pending
            ? `<div class="card__subtitle" style="font-size:11px">Apruébalo desde el panel central.</div>`
            : ''
        }
      </div>
    `;
  }

  /** Fase de la orden, para que la tarjeta de plan no mienta sobre su estado. */
  private orderPhase = '';

  public setPhase(phase: string): void {
    this.orderPhase = phase;
    if (this.currentPlan) this.renderPlan();
  }

  private planStatusBadge(): { text: string; cls: string; pending: boolean } {
    switch (this.orderPhase) {
      case 'running':
        return { text: 'Ejecutando', cls: 'badge--accent', pending: false };
      case 'done':
        return { text: 'Ejecutado', cls: 'badge--success', pending: false };
      case 'error':
        return { text: 'Con errores', cls: 'badge--danger', pending: false };
      case 'awaiting-approval':
        return { text: 'Pendiente de aprobar', cls: 'badge--accent', pending: true };
      default:
        return { text: 'Plan', cls: 'badge--accent', pending: false };
    }
  }

  private updateTimerText(): void {
    if (!this.startTimeMs) return;
    const elapsedSec = Math.floor((Date.now() - this.startTimeMs) / 1000);
    const mm = String(Math.floor(elapsedSec / 60)).padStart(2, '0');
    const ss = String(elapsedSec % 60).padStart(2, '0');
    this.elTimerText.textContent = `${mm}:${ss}`;
  }

  private scrollToBottom(): void {
    requestAnimationFrame(() => {
      this.elBody.scrollTop = this.elBody.scrollHeight;
    });
  }
}
