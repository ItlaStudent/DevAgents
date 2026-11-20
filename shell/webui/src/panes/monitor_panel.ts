import { escapeText as esc, escapeAttribute, html as safeHtml, joinHtml, raw } from '../design/html';
import { CoreApi, EngineStatusPayload, SessionInfo } from '../bridge/core_api';
import { icons } from '../design/icons';
import { formatEngineVersion } from '../layout/layout';
import { statusLabel, departmentLabel } from '../design/status_labels';
import type { BridgeClient } from '../bridge/client';

/**
 * Panel Monitor: estado vivo del sistema agéntico en una sola vista.
 *
 * El fork original (VS Code) traía un panel equivalente que agrupaba estado
 * del motor, sesiones, aprobaciones, salud de proveedores, especialistas y
 * ledger de auditoría. Esta cabina lo perdió al reescribirse; este panel lo
 * repone leyendo directamente de `CoreApi`, sin inventar endpoints nuevos.
 *
 * Los objetos de aprobaciones y salud vienen del motor como `unknown[]` con
 * forma variable (ver `core_api.ts`): cada campo se lee de forma defensiva
 * con varios alias posibles en vez de asumir un único esquema.
 */

interface CatalogInfo {
  catalog_path_abs: string;
  model_count: number;
  provider_count: number;
  key_count: number;
}

type Row = Record<string, unknown>;

const SECTIONS = ['resumen', 'sesiones', 'aprobaciones', 'salud', 'especialistas', 'evolucion', 'ledger'] as const;
type SectionKey = (typeof SECTIONS)[number];

export class MonitorPanel {
  private container: HTMLElement;
  private core: CoreApi | null;

  private autoRefreshOn = false;
  private autoRefreshMs = 5000;
  private timer: number | null = null;
  private loading = false;
  /** Firma de los datos pintados; igual = no se toca el DOM. */
  private lastSignature: string | null = null;
  /** Refresco agrupado: avisos del motor y reloj pasan por aquí. */
  private scheduledRefresh: number | null = null;
  private lastRefreshAt = 0;
  private deferredPaint: number | null = null;
  private pointerDown = false;
  /** Un gesto del usuario (refrescar, aprobar…) se pinta sin aplazar. */
  private userAction = false;
  private lastPointerAt = 0;
  private refreshPending = false;
  private approvalToFocus: number | null = null;
  /** Foco de aprobación que sobrevive al repintado del auto-refresco. */
  private approvalFocusRestore: number | null = null;
  /** Un refresco pedido por el usuario no debe devolver el foco a una fila. */
  private suppressApprovalFocus = false;
  /** Reintento de foco cuando la fila aún no existe al navegar. */
  private focusRetryTimer: number | null = null;

  private status: EngineStatusPayload | null = null;
  private catalog: CatalogInfo | null = null;
  private sessions: SessionInfo[] = [];
  private approvals: Row[] = [];
  private health: Row[] = [];
  private specialists: Row[] = [];
  private ledger: Row[] = [];

  /** Tierlist real que el motor calcula en cada auditoría (media móvil por modelo+tarea). */
  private modelScores: Row[] = [];
  /** Resumen evolutivo (top modelos, conteos, últimos barridos); complementa modelScores. */
  private evolution: Row | null = null;
  private evolutionError: string | null = null;

  private errors: Partial<Record<SectionKey, string>> = {};

  constructor(container: HTMLElement, core?: CoreApi, pushes?: Pick<BridgeClient, 'onPush'>) {
    this.container = container;
    this.core = core ?? null;
    // No refrescar aquí: refresh() dispara ledger/modelScores/evolution, las
    // lecturas más pesadas del motor, y en arranque en frío (DB con historial
    // grande) retenían la conexión compartida ~2 min, dejando mudo el bridge
    // entero. El panel se alimenta al abrir la vista Monitor (view-changed en
    // main.ts) — que es cuando el usuario realmente lo está mirando.
    this.paint();
    // Each WebView owns its subscription; the monitor keeps updating even
    // after the primary WebView has been closed. Respect the user's pause.
    pushes?.onPush((topic) => {
      if (topic === 'engine.changed' && this.autoRefreshOn) this.scheduleRefresh();
    });
    // 10-nov (propietario: «actualizaba cada microsegundo»): mientras el usuario
    // mueve o pulsa dentro del panel no se repinta (se aplaza un instante).
    container.addEventListener('pointermove', () => { this.lastPointerAt = Date.now(); });
    container.addEventListener('pointerdown', () => { this.pointerDown = true; this.lastPointerAt = Date.now(); });
    const release = () => { this.pointerDown = false; this.lastPointerAt = Date.now(); };
    container.addEventListener('pointerup', release);
    container.addEventListener('pointerleave', () => { this.pointerDown = false; this.lastPointerAt = 0; });
    container.addEventListener('pointercancel', release);
    container.addEventListener('wheel', () => { this.lastPointerAt = Date.now(); }, { passive: true });
  }

  // --- API pública ------------------------------------------------------

  public revealApproval(id: number): void {
    this.approvalToFocus = id;
    this.focusRequestedApproval();
    // La fila puede llegar con la lectura nativa o con un repintado posterior;
    // se reintenta mientras el objetivo siga pendiente, sin depender del orden.
    if (this.approvalToFocus !== null) this.scheduleFocusRetry();
  }

  private scheduleFocusRetry(): void {
    if (this.focusRetryTimer !== null) window.clearTimeout(this.focusRetryTimer);
    let attempts = 0;
    const tick = () => {
      this.focusRetryTimer = null;
      if (this.approvalToFocus === null) return;
      this.focusRequestedApproval();
      if (this.approvalToFocus !== null && attempts < 20) {
        attempts += 1;
        this.focusRetryTimer = window.setTimeout(tick, 100);
      }
    };
    this.focusRetryTimer = window.setTimeout(tick, 50);
  }

  public async refresh(): Promise<void> {
    if (this.loading) {
      this.refreshPending = true;
      return;
    }
    if (!this.core) {
      this.paint();
      return;
    }
    const core = this.core;
    this.loading = true;
    // Con datos ya pintados no se reconstruye el panel solo para enseñar
    // «cargando»: el botón lo indica y el resto no se mueve.
    if (this.lastSignature === null) this.paint();
    else this.markRefreshing(true);

    const [statusR, catalogR, sessionsR, approvalsR, healthR, specialistsR, ledgerR, scoresR, evolutionR] =
      await Promise.allSettled([
        core.status(),
        core.catalogInfo(),
        core.listSessions(),
        core.pendingApprovals(),
        core.health(),
        core.specialists(),
        core.ledger(),
        core.modelScores(),
        core.evolution(),
      ]);

    if (statusR.status === 'fulfilled') {
      this.status = statusR.value;
      delete this.errors.resumen;
    } else {
      this.errors.resumen = String(statusR.reason);
    }

    if (catalogR.status === 'fulfilled') {
      this.catalog = catalogR.value as CatalogInfo;
    } else {
      // El resumen ya muestra el error de `status`; el de catálogo no pisa ese mensaje.
      this.errors.resumen = this.errors.resumen || String(catalogR.reason);
    }

    if (sessionsR.status === 'fulfilled') {
      this.sessions = sessionsR.value || [];
      delete this.errors.sesiones;
    } else {
      this.errors.sesiones = String(sessionsR.reason);
    }

    if (approvalsR.status === 'fulfilled') {
      this.approvals = (approvalsR.value as Row[]) || [];
      delete this.errors.aprobaciones;
    } else {
      this.errors.aprobaciones = String(approvalsR.reason);
    }

    if (healthR.status === 'fulfilled') {
      this.health = (healthR.value as Row[]) || [];
      delete this.errors.salud;
    } else {
      this.errors.salud = String(healthR.reason);
    }

    if (specialistsR.status === 'fulfilled') {
      const payload = specialistsR.value as { specialists?: Row[] } | Row[];
      this.specialists = Array.isArray(payload) ? payload : payload?.specialists || [];
      delete this.errors.especialistas;
    } else {
      this.errors.especialistas = String(specialistsR.reason);
    }

    if (ledgerR.status === 'fulfilled') {
      this.ledger = (ledgerR.value as Row[]) || [];
      delete this.errors.ledger;
    } else {
      this.errors.ledger = String(ledgerR.reason);
    }

    if (scoresR.status === 'fulfilled') {
      this.modelScores = (scoresR.value as Row[]) || [];
      delete this.errors.evolucion;
    } else {
      this.errors.evolucion = String(scoresR.reason);
    }

    // Complementa la tabla de puntuaciones; su fallo no debe tapar la tabla si esta sí cargó.
    if (evolutionR.status === 'fulfilled') {
      this.evolution = (evolutionR.value as Row) || null;
      this.evolutionError = null;
    } else {
      this.evolution = null;
      this.evolutionError = String(evolutionR.reason);
    }

    this.loading = false;
    const signature = this.dataSignature();
    if (signature !== this.lastSignature) {
      this.lastSignature = signature;
      this.paint();
    } else {
      // Nada cambió: el DOM (scroll, foco, botones bajo el cursor) se queda igual.
      this.markRefreshing(false);
      this.userAction = false;
    }
    this.suppressApprovalFocus = false;
    if (this.refreshPending) {
      this.refreshPending = false;
      void this.refresh();
    }
  }

  /**
   * 10-nov: un único punto de entrada para los refrescos automáticos. Antes
   * cada `engine.changed` (varios por segundo con una orden en marcha) lanzaba
   * 9 lecturas del motor y reconstruía el panel entero. Ahora: como mucho uno
   * cada `autoRefreshMs`, ninguno con el Monitor fuera de la vista.
   */
  private scheduleRefresh(): void {
    if (!this.isVisible() || this.scheduledRefresh !== null) return;
    const wait = Math.max(0, this.lastRefreshAt + this.autoRefreshMs - Date.now());
    this.scheduledRefresh = window.setTimeout(() => {
      this.scheduledRefresh = null;
      if (!this.isVisible()) return;
      this.lastRefreshAt = Date.now();
      void this.refresh();
    }, wait);
  }

  private isVisible(): boolean {
    const doc = this.container.ownerDocument;
    if (doc?.hidden) return false;
    return this.container.isConnected !== false && this.container.getClientRects().length > 0;
  }

  private isInteracting(): boolean {
    if (this.userAction) return false;
    return this.pointerDown || Date.now() - this.lastPointerAt < 1500;
  }

  private markRefreshing(busy: boolean): void {
    const btn = this.container.querySelector<HTMLButtonElement>('#mon-refresh');
    if (btn) btn.disabled = busy;
  }

  /** Lo que se pinta, serializado: si no cambia, no hay repintado. */
  private dataSignature(): string {
    try {
      return JSON.stringify([
        this.status, this.catalog, this.sessions, this.approvals, this.health,
        this.specialists, this.ledger, this.modelScores, this.evolution,
        this.evolutionError, this.errors, this.autoRefreshOn,
      ]);
    } catch {
      return String(Date.now());
    }
  }

  public startAutoRefresh(intervalMs = 5000): void {
    this.stopAutoRefresh();
    this.autoRefreshMs = intervalMs;
    this.autoRefreshOn = true;
    this.timer = window.setInterval(() => this.scheduleRefresh(), this.autoRefreshMs);
    this.paint();
  }

  public stopAutoRefresh(): void {
    if (this.scheduledRefresh !== null) {
      window.clearTimeout(this.scheduledRefresh);
      this.scheduledRefresh = null;
    }
    if (this.timer !== null) {
      window.clearInterval(this.timer);
      this.timer = null;
    }
    this.autoRefreshOn = false;
  }

  // --- Render -------------------------------------------------------------

  private paint(): void {
    if (this.isInteracting()) {
      if (this.deferredPaint === null) {
        this.deferredPaint = window.setTimeout(() => {
          this.deferredPaint = null;
          this.paint();
        }, 600);
      }
      return;
    }
    if (this.deferredPaint !== null) {
      window.clearTimeout(this.deferredPaint);
      this.deferredPaint = null;
    }
    this.userAction = false;
    const scrollTop = this.container.scrollTop;
    const innerScroll = new Map<string, number>();
    this.container.querySelectorAll<HTMLElement>('[data-mon-scroll]').forEach((el) => {
      innerScroll.set(el.dataset.monScroll ?? '', el.scrollTop);
    });
    // Se captura el id enfocado ANTES de que `innerHTML` destruya el nodo,
    // en cada repintado (incluido el intermedio con loading=true): el foco
    // debe sobrevivir al auto-refresco y a los refresh encolados.
    if (!this.suppressApprovalFocus) {
      const focused = this.focusedApprovalId();
      if (focused !== null) {
        this.approvalFocusRestore = focused;
      } else {
        // el segundo auditor lote AD P2: el foco restaurado solo vive mientras sea el foco
        // REAL del usuario sobre esa aprobación. Si ahora está en otro control
        // (dentro o fuera del panel), una actualización posterior que devuelva
        // la fila no le roba el foco. El caso BODY no limpia: un repintado
        // propio destruye el botón enfocado y deja activeElement en BODY, y
        // ahí el objetivo debe sobrevivir al auto-refresco (r2/r3).
        const doc = this.container.ownerDocument;
        const active = doc?.activeElement;
        if (active && active !== doc.body) this.approvalFocusRestore = null;
      }
    }

    if (!this.core) {
      this.container.innerHTML = `
        <div class="empty-state" style="height:100%">
          ${icons.bolt(28)}
          <span class="empty-state__title">Monitor no disponible</span>
          <span>El puente con el motor no está conectado, así que no hay estado que mostrar.</span>
        </div>`;
      return;
    }

    this.container.innerHTML = `
      <div class="col" style="gap:16px;padding:20px;max-width:1100px;width:100%;margin:0 auto">
        ${this.renderHeader()}
        ${this.renderResumen()}
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:16px">
          ${this.renderSesiones()}
          ${this.renderAprobaciones()}
        </div>
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:16px">
          ${this.renderSalud()}
          ${this.renderEspecialistas()}
        </div>
        ${this.renderEvolucion()}
        ${this.renderLedger()}
      </div>`;

    this.bind();
    this.container.scrollTop = scrollTop;
    this.container.querySelectorAll<HTMLElement>('[data-mon-scroll]').forEach((el) => {
      const top = innerScroll.get(el.dataset.monScroll ?? '');
      if (top) el.scrollTop = top;
    });
    this.focusRequestedApproval(this.approvalFocusRestore);
  }

  /** Id de la aprobación que tiene el foco dentro del panel, si lo hay. */
  private focusedApprovalId(): number | null {
    const active = this.container.ownerDocument?.activeElement as HTMLElement | null | undefined;
    if (!active || !this.container.contains(active)) return null;
    const id = Number(active.dataset?.approve);
    return Number.isSafeInteger(id) && id > 0 ? id : null;
  }

  private focusRequestedApproval(restore: number | null = null): void {
    const target = this.approvalToFocus ?? restore;
    if (target === null) return;
    const button = this.container.querySelector<HTMLElement>(`[data-approve="${target}"]`);
    // La fila puede no estar todavía en la lista; se conserva el objetivo
    // para el siguiente repintado en vez de descartarlo en silencio.
    if (!button) return;
    button.scrollIntoView({ block: 'center' });
    button.focus({ preventScroll: true });
    if (this.focusRetryTimer !== null) {
      window.clearTimeout(this.focusRetryTimer);
      this.focusRetryTimer = null;
    }
    this.approvalFocusRestore = null;
    this.approvalToFocus = null;
  }

  private renderHeader(): string {
    const ready = !!this.status?.engineReady;
    return `
      <div class="row" style="justify-content:space-between;flex-wrap:wrap;gap:10px">
        <div class="col" style="gap:4px">
          <span style="font-size:15px;font-weight:600">Monitor</span>
          <span class="card__subtitle">Estado vivo del sistema agéntico: motor, sesiones, aprobaciones y auditoría.</span>
        </div>
        <div class="row" style="gap:8px">
          <span class="pill ${ready ? 'pill--online' : 'pill--offline'}">
            <span class="pill__dot"></span>${ready ? 'Motor en línea' : 'Motor no disponible'}
          </span>
          <button class="btn btn--sm ${this.autoRefreshOn ? 'btn--primary' : ''}" id="mon-auto" title="Activar o pausar el refresco automático">
            ${icons.clock(13)} Auto-refresco: ${this.autoRefreshOn ? 'activado' : 'desactivado'}
          </button>
          <button class="btn btn--sm" id="mon-refresh" title="Recargar el estado ahora" ${this.loading ? 'disabled' : ''}>
            ${this.loading ? '<span class="spinner"></span>' : icons.refresh(13)} Refrescar
          </button>
          <button class="icon-btn" id="mon-popout" title="Abrir el Monitor en una ventana nueva">&#10697;</button>
        </div>
      </div>`;
  }

  private renderResumen(): string {
    if (this.errors.resumen) return this.errorCard('Resumen', this.errors.resumen);
    const st = this.status;
    const cat = this.catalog;
    const stats: Array<[string, string]> = [
      ['Versión', formatEngineVersion(st?.version)],
      ['PID', st ? String(st.pid) : '—'],
      ['Proveedores', st ? String(st.providerCount) : '—'],
      ['Claves', st ? String(st.keyCount) : '—'],
      ['Modelos en catálogo', cat ? String(cat.model_count) : '—'],
      ['Modelo de planificación', planningModelLabel(st)],
      ['Gobernanza', governanceLabel(st?.governanceMode)],
    ];
    return `
      <div class="card col" style="gap:12px">
        <span class="section-label">Resumen</span>
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px">
          ${stats
            .map(
              ([label, value]) => `
            <div class="col" style="gap:3px;padding:10px 12px;border-radius:var(--radius-sm);background:var(--surface-2)">
              <span style="font-size:19px;font-weight:700;color:var(--fg)" class="truncate" title="${escapeAttribute(value)}">${esc(value)}</span>
              <span class="section-label">${esc(label)}</span>
            </div>`
            )
            .join('')}
        </div>
      </div>`;
  }

  private renderSesiones(): string {
    if (this.errors.sesiones) return this.errorCard('Sesiones', this.errors.sesiones);
    const rows = this.sessions;
    return `
      <div class="card col" style="gap:10px">
        <span class="section-label">Sesiones (${rows.length})</span>
        ${
          rows.length
            ? // Alto acotado con scroll propio, como "Evolución del router". Con
              // 40 sesiones la tarjeta medía media pantalla y obligaba a
              // recorrer el Monitor entero para llegar a lo de abajo. Unas 15
              // filas caben en 420px; el resto se desplaza aquí dentro.
              `<div class="col" data-mon-scroll="sesiones" style="gap:2px;max-height:450px;overflow-y:auto">
                ${joinHtml(rows
                  .map((s) => {
                    const id = s.id ?? s.order_id ?? 0;
                    const title = s.title || `Sesión #${id}`;
                    const status = statusLabel(s.status_text ?? s.status) || '—';
                    return safeHtml`<div class="row" style="justify-content:space-between;padding:6px 8px;border-radius:var(--radius-sm)">
                      <div class="row" style="gap:8px;min-width:0">
                        <span class="subtle mono" style="min-width:36px">#${String(id)}</span>
                        <span class="truncate">${String(title)}</span>
                      </div>
                      <span class="badge">${String(status)}</span>
                    </div>`;
                  })).value}
              </div>`
            : '<div class="empty-state"><span>No hay ninguna sesión todavía.</span></div>'
        }
      </div>`;
  }

  private renderAprobaciones(): string {
    if (this.errors.aprobaciones) return this.errorCard('Aprobaciones pendientes', this.errors.aprobaciones);
    const rows = this.approvals;
    return `
      <div class="card col" style="gap:10px">
        <span class="section-label">Aprobaciones pendientes (${rows.length})</span>
        ${
          rows.length
            ? `<div class="col" style="gap:8px">
                ${joinHtml(rows
                  .map((r, i) => {
                    const id = r.id ?? r.approval_id ?? '';
                    // El núcleo ya escapa exe/argv en description. Se hacen
                    // visibles controles residuales (p. ej. cwd) sin doblar
                    // otra vez las barras de ese comando saneado.
                    const fullText = String(r.description ?? r.task_id ?? 'Sin descripción');
                    const desc = visibleApprovalText(fullText, false);
                    // 10-nov (propietario): resumen corto en una línea; el comando
                    // completo (a veces una página HTML entera) queda plegado.
                    const oneLine = fullText.replace(/\s+/g, ' ').trim();
                    const long = oneLine.length > APPROVAL_SUMMARY_CHARS || /[\r\n]/.test(fullText);
                    const summary = visibleApprovalText(long ? `${oneLine.slice(0, APPROVAL_SUMMARY_CHARS)}…` : oneLine, false);
                    const meta: string[] = [];
                    if (r.task_id) meta.push(`tarea: ${visibleApprovalText(String(r.task_id))}`);
                    if (r.command_prefix) meta.push(`comando: ${visibleApprovalText(String(r.command_prefix))}`);
                    if (r.exe) meta.push(`ejecutable: ${visibleApprovalText(String(r.exe))}`);
                    // E5.05: la aprobación de un script de setup lleva en
                    // args_json {project_id, script_sha256, script} — la
                    // tarjeta muestra QUÉ script y QUÉ hash se aprueban.
                    if (r.command_prefix === 'worktree_script' && r.args_json) {
                      try {
                        const args = JSON.parse(String(r.args_json)) as { script?: string; script_sha256?: string };
                        if (args.script) meta.push(`script: ${visibleApprovalText(String(args.script))}`);
                        if (args.script_sha256) meta.push(`sha256: ${visibleApprovalText(String(args.script_sha256).slice(0, 16))}…`);
                      } catch {
                        meta.push('args_json ilegible');
                      }
                    }
                    if (r.order_id !== undefined) meta.push(`orden #${visibleApprovalText(String(r.order_id))}`);
                    return safeHtml`<div class="row" style="justify-content:space-between;gap:12px;padding:8px 10px;border-radius:var(--radius-sm);background:var(--surface-2);align-items:flex-start">
                      <div class="col" style="gap:2px;min-width:0">
                        <span class="approval-summary">${summary}</span>
                        ${long ? safeHtml`<details class="approval-detail"><summary>Ver comando completo</summary><pre>${desc}</pre></details>` : ''}
                        ${meta.length ? safeHtml`<span class="subtle" style="font-size:11px">${meta.join(' · ')}</span>` : ''}
                      </div>
                      <div class="row" style="gap:6px;flex:0 0 auto">
                        <button class="btn btn--sm btn--primary" data-approve="${String(id)}" data-idx="${i}" title="Aprobar esta solicitud">${raw(icons.check(12))} Aprobar</button>
                        <button class="btn btn--sm btn--danger" data-reject="${String(id)}" data-idx="${i}" title="Rechazar esta solicitud">${raw(icons.close(12))} Rechazar</button>
                      </div>
                    </div>`;
                  })).value}
              </div>`
            : '<div class="empty-state"><span>No hay aprobaciones pendientes.</span></div>'
        }
      </div>`;
  }

  private renderSalud(): string {
    if (this.errors.salud) return this.errorCard('Salud de proveedores', this.errors.salud);
    const rows = this.health;
    return `
      <div class="card col" style="gap:10px">
        <div class="row" style="justify-content:space-between">
          <span class="section-label">Salud de proveedores (${rows.length})</span>
          <button class="btn btn--sm" id="mon-probe" title="Sondear la salud de los modelos ahora">${icons.bolt(12)} Sondear ahora</button>
        </div>
        ${
          rows.length
            ? // 91 modelos en una sola columna hacían del Monitor una página
              // interminable. Mismo criterio que en Sesiones: alto acotado y
              // scroll dentro de la propia tarjeta.
              `<div class="col" data-mon-scroll="salud" style="gap:8px;max-height:420px;overflow-y:auto">
                ${rows.map((r) => this.renderHealthRow(r)).join('')}
              </div>`
            : '<div class="empty-state"><span>Sin datos de salud todavía. Sondea los proveedores para generarlos.</span></div>'
        }
      </div>`;
  }

  private renderHealthRow(r: Row): string {
    const label = String(r.provider ?? r.model_id ?? r.model ?? r.name ?? '—');
    const totalOk = numOf(r.total_ok ?? r.ok_count);
    const totalFail = numOf(r.total_fail ?? r.total_err ?? r.err_count) + numOf(r.total_timeout ?? r.timeout_count);
    const total = totalOk + totalFail;
    let rate = numOrNull(r.ok_rate);
    if (rate === null) rate = total > 0 ? totalOk / total : null;

    const pct = rate === null ? 0 : Math.max(0, Math.min(1, rate));
    const barColor = rate === null ? 'var(--fg-subtle)' : pct > 0.8 ? 'var(--success)' : pct > 0.5 ? 'var(--warning)' : 'var(--danger)';
    const extra: string[] = [];
    if (r.models !== undefined) extra.push(`modelos: ${String(r.models)}`);
    if (r.ok_models !== undefined) extra.push(`ok: ${String(r.ok_models)}`);
    if (r.models === undefined && r.ok_models === undefined) extra.push(`${totalOk} ok / ${totalFail} fallo(s)`);

    return `
      <div class="col" style="gap:5px">
        <div class="row" style="justify-content:space-between">
          <span class="truncate">${esc(label)}</span>
          <span class="subtle" style="font-size:11px">${rate === null ? 'sin datos' : `${Math.round(pct * 100)}%`}</span>
        </div>
        <div style="height:6px;border-radius:var(--radius-pill,999px);background:var(--surface-2);overflow:hidden">
          <div style="height:100%;width:${Math.round(pct * 100)}%;background:${barColor}"></div>
        </div>
        <span class="subtle" style="font-size:11px">${esc(extra.join(' · '))}</span>
      </div>`;
  }

  private renderEspecialistas(): string {
    if (this.errors.especialistas) return this.errorCard('Especialistas / departamentos', this.errors.especialistas);
    const rows = this.specialists;
    return `
      <div class="card col" style="gap:10px">
        <span class="section-label">Especialistas / departamentos (${rows.length})</span>
        ${
          rows.length
            ? `<div class="col" style="gap:8px">
                ${joinHtml(rows
                  .map((s) => {
                    const name = String(s.name ?? '—');
                    const dept = String(s.department ?? '');
                    const taskTypes = Array.isArray(s.task_types) ? (s.task_types as unknown[]) : [];
                    const desc = String(s.description ?? '');
                    return safeHtml`<div class="col" style="gap:3px">
                      <!-- flex-wrap: sin él, las etiquetas de tipos de tarea
                           (hasta seis por especialista) se salían de la tarjeta
                           al estrechar la ventana en vez de bajar de línea. -->
                      <div class="row" style="gap:6px;flex-wrap:wrap;align-items:center">
                        <span style="font-weight:600">${name}</span>
                        ${dept ? safeHtml`<span class="badge badge--accent">${departmentLabel(dept)}</span>` : ''}
                        ${taskTypes.map((t) => safeHtml`<span class="badge">${String(t)}</span>`)}
                      </div>
                      ${desc ? safeHtml`<span style="color:var(--fg-muted);font-size:12px">${desc}</span>` : ''}
                    </div>`;
                  })).value}
              </div>`
            : '<div class="empty-state"><span>El motor no reporta especialistas.</span></div>'
        }
      </div>`;
  }

  /**
   * Tierlist real del router: `core.modelScores()` trae una fila por
   * modelo+task_type con la puntuación que el motor ajusta tras cada
   * auditoría (media móvil). `core.evolution()` añade contexto (conteos y
   * últimos barridos) pero no es indispensable para pintar la tabla, así que
   * su fallo se muestra aparte sin tapar los datos de puntuación si esos sí
   * llegaron.
   */
  private renderEvolucion(): string {
    if (this.errors.evolucion) return this.errorCard('Evolución del router', this.errors.evolucion);

    const rows = [...this.modelScores].sort((a, b) => numOf(b.score) - numOf(a.score));

    const ev = this.evolution;
    const summaryBits: string[] = [];
    if (ev) {
      if (ev.order_count !== undefined) summaryBits.push(`${String(ev.order_count)} orden(es) procesada(s)`);
      if (ev.lesson_count !== undefined) summaryBits.push(`${String(ev.lesson_count)} lección(es) registrada(s)`);
      const lastProbe = numOf(ev.last_probe_ts);
      if (lastProbe > 0) summaryBits.push(`último sondeo: ${formatTs(lastProbe)}`);
      const lastSweep = numOf(ev.last_pricing_sweep_ts);
      if (lastSweep > 0) summaryBits.push(`último barrido de precios: ${formatTs(lastSweep)}`);
    }

    // Un span por bit: el i18n traduce nodo a nodo y el joined « · » sería
    // un solo texto intraducible por partes.
    const summaryLine = summaryBits.length
      ? `<span class="subtle" style="font-size:11px">${summaryBits.map((b) => `<span>${esc(b)}</span>`).join(' · ')}</span>`
      : '';
    const evolutionErrLine = this.evolutionError
      ? `<span style="color:var(--danger);font-size:11px">${esc(this.evolutionError)}</span>`
      : '';

    const body = rows.length
      ? `<div data-mon-scroll="evolucion" style="max-height:360px;overflow:auto;border:1px solid var(--border);border-radius:var(--radius-sm)">
          <table style="width:100%;border-collapse:collapse;font-size:12px">
            <thead>
              <tr>
                ${['Modelo', 'Proveedor', 'Tipo de tarea', 'Puntuación', 'Muestras', 'Nivel']
                  .map(
                    (h) =>
                      `<th style="position:sticky;top:0;background:var(--surface-2);text-align:left;padding:6px 10px;border-bottom:1px solid var(--border)">${h}</th>`
                  )
                  .join('')}
              </tr>
            </thead>
            <tbody>
              ${rows
                .map((r, i) => {
                  const score = numOf(r.score);
                  const rowBg = i % 2 === 1 ? 'background:var(--surface-1)' : '';
                  return `<tr style="${rowBg}">
                    <td style="padding:6px 10px" class="mono">${esc(String(r.model ?? r.model_name ?? '—'))}</td>
                    <td style="padding:6px 10px">${esc(String(r.provider ?? '—'))}</td>
                    <td style="padding:6px 10px">${esc(String(r.task_type ?? '—'))}</td>
                    <td style="padding:6px 10px" class="mono">${score.toFixed(2)}</td>
                    <td style="padding:6px 10px">${esc(String(r.samples ?? r.sample_count ?? 0))}</td>
                    <td style="padding:6px 10px">${scoreBadge(score)}</td>
                  </tr>`;
                })
                .join('')}
            </tbody>
          </table>
        </div>`
      : `<div class="empty-state">
          ${icons.layers(22)}
          <span class="empty-state__title">Sin puntuaciones todavía</span>
          <span>Las puntuaciones aparecen aquí cuando el motor haya auditado tareas resueltas por cada modelo.</span>
        </div>`;

    return `
      <div class="card col" style="gap:10px">
        <div class="row" style="justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:6px">
          <span class="section-label">Evolución del router (${rows.length})</span>
          ${summaryLine}
        </div>
        ${evolutionErrLine}
        ${body}
      </div>`;
  }

  private renderLedger(): string {
    if (this.errors.ledger) return this.errorCard('Ledger de auditoría', this.errors.ledger);
    const rows = this.ledger.slice(-50).reverse();
    return `
      <div class="card col" style="gap:10px">
        <span class="section-label">Ledger de auditoría (últimas ${rows.length})</span>
        ${
          rows.length
            ? `<div class="col code-surface" data-mon-scroll="ledger" style="gap:2px;max-height:320px;overflow-y:auto">
                ${rows
                  .map((r) => {
                    const verdict = String(r.verdict ?? r.veredicto ?? '');
                    const color =
                      verdict.toUpperCase() === 'PASS'
                        ? 'var(--success)'
                        : verdict.toUpperCase() === 'FAIL'
                          ? 'var(--danger)'
                          : 'var(--fg-muted)';
                    const action = String(r.action ?? '—');
                    const model = String(r.model_id ?? r.model ?? r.provider ?? '—');
                    return `<div class="row" style="gap:10px;padding:2px 0">
                      <span style="color:${color};min-width:70px;font-size:11px">[${esc(verdict || '—')}]</span>
                      <span class="subtle truncate" style="min-width:140px">${esc(action)}</span>
                      <span class="truncate">${esc(model)}</span>
                    </div>`;
                  })
                  .join('')}
              </div>`
            : '<div class="empty-state"><span>El ledger está vacío.</span></div>'
        }
      </div>`;
  }

  private errorCard(title: string, message: string): string {
    return `
      <div class="card col" style="gap:8px">
        <span class="section-label">${esc(title)}</span>
        <span style="color:var(--danger)">${esc(message)}</span>
      </div>`;
  }

  private bind(): void {
    this.container.querySelector('#mon-refresh')?.addEventListener('click', () => {
      // Refresco explícito: el usuario ya eligió dónde está; no se le mueve
      // el foco de vuelta a la solicitud que dejó.
      if (this.focusRetryTimer !== null) {
        window.clearTimeout(this.focusRetryTimer);
        this.focusRetryTimer = null;
      }
      this.approvalToFocus = null;
      this.approvalFocusRestore = null;
      this.suppressApprovalFocus = true;
      this.userAction = true;
      void this.refresh();
    });

    // E5.22: el gesto se publica como evento DOM; main lo traduce a
    // `window.open` del puente (el panel no conoce al host directamente).
    // se publica en `document`, donde escucha main.ts (como el
    // chat); publicado en `window` no llegaba y el botón no abría nada.
    this.container.querySelector('#mon-popout')?.addEventListener('click', () => {
      document.dispatchEvent(new CustomEvent('devagents:open-window', { detail: { vista: 'monitor' } }));
    });

    this.container.querySelector('#mon-auto')?.addEventListener('click', () => {
      this.userAction = true;
      if (this.autoRefreshOn) {
        this.stopAutoRefresh();
        this.paint();
      } else {
        this.startAutoRefresh(this.autoRefreshMs);
      }
    });

    this.container.querySelector('#mon-probe')?.addEventListener('click', async () => {
      if (!this.core) return;
      try {
        await this.core.probeHealth(8);
        await this.refresh();
      } catch (e) {
        this.errors.salud = String(e);
        this.paint();
      }
    });

    this.container.querySelectorAll<HTMLElement>('[data-approve]').forEach((btn) => {
      btn.addEventListener('click', () => void this.resolve(btn.dataset.approve, true));
    });
    this.container.querySelectorAll<HTMLElement>('[data-reject]').forEach((btn) => {
      btn.addEventListener('click', () => void this.resolve(btn.dataset.reject, false));
    });
  }

  private async resolve(idRaw: string | undefined, approved: boolean): Promise<void> {
    if (!this.core || idRaw === undefined) return;
    const id = Number(idRaw);
    if (!Number.isFinite(id)) return;
    this.userAction = true;
    try {
      await this.core.resolveApproval(id, approved);
      await this.refresh();
    } catch (e) {
      this.errors.aprobaciones = String(e);
      this.paint();
    }
  }
}



/** H13: mismo escape visible que executor.escapeCodePointInto.
 * safeHtml aplica después el escape HTML; son dos contextos diferentes.
 * Los metadatos se muestran completos, sin cortar un posible sufijo peligroso.
 */
/** Caracteres del resumen de una aprobación antes de plegar el resto. */
const APPROVAL_SUMMARY_CHARS = 140;

function visibleApprovalText(value: string, escapeBackslashes = true): string {
  let visible = '';
  for (const char of value) {
    const cp = char.codePointAt(0)!;
    if (char === '\n') visible += '\\n';
    else if (char === '\r') visible += '\\r';
    else if (char === '\\') visible += escapeBackslashes ? '\\\\' : '\\';
    else if (cp < 0x20 || (cp >= 0x7F && cp <= 0x9F) ||
      cp === 0x00AD || cp === 0x034F || cp === 0x061C ||
      (cp >= 0x115F && cp <= 0x1160) || (cp >= 0x17B4 && cp <= 0x17B5) ||
      (cp >= 0x180B && cp <= 0x180F) || (cp >= 0x200B && cp <= 0x200F) ||
      (cp >= 0x2028 && cp <= 0x202E) || (cp >= 0x2060 && cp <= 0x206F) ||
      cp === 0x3164 || (cp >= 0xFE00 && cp <= 0xFE0F) || cp === 0xFEFF || cp === 0xFFA0 ||
      (cp >= 0xFFF0 && cp <= 0xFFF8) || (cp >= 0x1BCA0 && cp <= 0x1BCA3) ||
      (cp >= 0x1D173 && cp <= 0x1D17A) || (cp >= 0xE0000 && cp <= 0xE0FFF)) {
      visible += `\\u{${cp.toString(16).toUpperCase().padStart(4, '0')}}`;
    } else if (cp >= 0xD800 && cp <= 0xDFFF) visible += '\\u{FFFD}';
    else visible += char;
  }
  return visible;
}

function numOf(v: unknown): number {
  const n = Number(v);
  return Number.isFinite(n) ? n : 0;
}

function numOrNull(v: unknown): number | null {
  if (v === undefined || v === null) return null;
  const n = Number(v);
  return Number.isFinite(n) ? n : null;
}

/** Insignia de nivel para la puntuación 0..1 que calcula el router tras cada auditoría. */
function scoreBadge(score: number): string {
  if (score >= 0.8) return '<span class="badge badge--success">Alto</span>';
  if (score >= 0.5) return '<span class="badge badge--warning">Medio</span>';
  return '<span class="badge badge--danger">Bajo</span>';
}

/** Timestamps del motor son epoch en segundos. */
function formatTs(tsSeconds: number): string {
  if (!Number.isFinite(tsSeconds) || tsSeconds <= 0) return '—';
  return new Date(tsSeconds * 1000).toLocaleString('es-ES');
}

/** El motor guarda el modo en inglés; la interfaz es en español. */
function governanceLabel(mode?: string): string {
  switch (mode) {
    case 'free':
    case 'free_tier_first':
      return 'Solo gratis';
    case 'paid':
    case 'paid_tier_first':
      return 'Prioriza pago';
    case 'hybrid':
      return 'Híbrido';
    case 'local':
    case 'local_only':
    case 'solo_local':
      return 'Solo local';
    default:
      return mode || '—';
  }
}

/**
 * El motor no siempre tiene un único modelo de planificación: sin pin del
 * usuario el router elige por tarea y `core_client.cpp` rellena el campo con
 * literal `auto (router)`. En la tarjeta eso salía como «— / auto (rou…».
 * Se lee «Automático (router)» o «proveedor / modelo» cuando sí hay pin.
 */
function planningModelLabel(st: EngineStatusPayload | null): string {
  if (!st) return '—';
  const model = (st.activeModel || '').trim();
  const provider = (st.activeProvider || '').trim();
  if (!model || /^auto( \(router\))?$/i.test(model)) return 'Automático (router)';
  return provider ? `${provider} / ${model}` : model;
}

