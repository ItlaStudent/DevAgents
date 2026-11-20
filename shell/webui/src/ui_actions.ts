import { CoreApi, UiActionRow } from './bridge/core_api';
import { notice } from './design/notice';
import { ViewId } from './layout/layout';
import { relativePreviewPath } from './preview_elements';

/**
 * UI-ACTION: despacha acciones cosméticas pedidas por agentes/órdenes.
 *
 * Doble puerta: el motor ya validó `action` contra `executor.UI_ACTIONS` al
 * escribir el evento; aquí se revalida antes de tocar la UI (defensa en
 * profundidad — un evento corrupto o una cabina vieja no ejecutan nada raro).
 * Cada acción aplicada/rechazada se reporta al motor con `uiActionAck` para
 * que el agente que la pidió vea el resultado en `ui_action_result`.
 */

const ALLOWED_ACTIONS = new Set(['set_theme', 'open_view', 'focus_session', 'notify', 'open_window']);
const VALID_VIEWS = new Set<string>([
  'agent', 'explorer', 'search', 'monitor', 'spaces', 'mcp', 'settings', 'diff',
]);
// E5.21: vistas que una ventana secundaria sabe montar en modo aislado.
// El host revalida igualmente con ParseOpenWindow (defensa en profundidad).
const SECONDARY_VIEWS = new Set<string>(['editor', 'terminal', 'conversacion', 'monitor', 'preview']);

export interface UiActionDeps {
  applyTheme(themeId: string): void;
  hasTheme(themeId: string): boolean;
  showView(view: string): void;
  focusSession(sessionId: string): void;
  /**
 * T8: `open_view {view:"order_graph"}` — el agente pide ver el
   * grafo de su orden. Solo cambia la vista (abre la conversación y enciende
   * el grafo); nunca toca permisos ni aprobaciones. Sin él, se rechaza.
   */
  showOrderGraph?(): void;
  /** E5.21: abre una ventana secundaria nativa (puente `window.open`). */
  openWindow(args: { vista: string; path?: string; order_id?: number }): Promise<{ window_id?: number }>;
}

export class UiActionDispatcher {
  private lastId = 0;
  private pollTimer: number | null = null;

  constructor(
    private core: CoreApi,
    private deps: UiActionDeps,
  ) {
    // el watermark sobrevive a recargas. Antes `lastId` arrancaba en 0,
    // así que cada load de la cabina re-pedía el historial COMPLETO de
    // ui_actions y re-ackeaba cada una — ~100 llamadas en ráfaga que dejaban
    // el bridge mudo ~1 min. El motor además ya filtra las acciones con ack,
    // así que esto solo acota la ventana al primer arranque real del perfil.
    try {
      const saved = Number(window.localStorage.getItem('devagents.ui_actions.lastId'));
      if (Number.isFinite(saved) && saved > 0) this.lastId = saved;
    } catch {
      // localStorage inaccesible: se sondea desde 0 como antes.
    }
  }

  private saveWatermark(): void {
    try {
      window.localStorage.setItem('devagents.ui_actions.lastId', String(this.lastId));
    } catch {
      // best-effort: sin storage el sondeo sigue funcionando en memoria.
    }
  }

  /** Arranca el sondeo global (acciones MCP/externas con order_id=0). */
  start(intervalMs = 1500): void {
    if (this.pollTimer !== null) return;
    this.pollTimer = window.setInterval(() => void this.poll(), intervalMs);
  }

  stop(): void {
    if (this.pollTimer !== null) {
      window.clearInterval(this.pollTimer);
      this.pollTimer = null;
    }
  }

  private async poll(): Promise<void> {
    try {
      const rows = await this.core.uiActions(this.lastId);
      for (const row of rows) {
        this.lastId = Math.max(this.lastId, row.id);
        if (row.kind === 'ui_action') await this.apply(row.id, row.payload);
      }
      if (rows.length) this.saveWatermark();
    } catch {
      // best-effort: un fallo puntual del bridge no rompe el sondeo.
    }
  }

  /**
   * Punto de entrada para eventos de una orden (mission_control drena
   * `core.order.events` y nos pasa los `kind==='ui_action'` aquí).
   */
  async handleOrderEvent(eventId: number, payload: UiActionRow['payload']): Promise<void> {
    if (eventId > this.lastId) {
      this.lastId = eventId;
      this.saveWatermark();
    }
    await this.apply(eventId, payload);
  }

  private async apply(eventId: number, payload: UiActionRow['payload']): Promise<void> {
    const action = payload?.action ?? '';
    const args = payload?.args ?? {};
    let ok = false;
    let detail = '';

    if (!ALLOWED_ACTIONS.has(action)) {
      detail = `acción no permitida: ${action || '(vacía)'}`;
    } else {
      try {
        switch (action) {
          case 'set_theme': {
            const theme = args.theme ?? '';
            if (!theme || !this.deps.hasTheme(theme)) {
              detail = `tema desconocido: ${theme || '(vacío)'}`;
              break;
            }
            this.deps.applyTheme(theme);
            ok = true;
            detail = `tema aplicado: ${theme}`;
            break;
          }
          case 'open_view': {
            const view = args.view ?? '';
            if (view === 'order_graph') {
              if (!this.deps.showOrderGraph) {
                detail = 'esta cabina no sabe mostrar el grafo de la orden';
                break;
              }
              this.deps.showOrderGraph();
              ok = true;
              detail = 'grafo de la orden mostrado';
              break;
            }
            if (!VALID_VIEWS.has(view)) {
              detail = `vista desconocida: ${view || '(vacía)'}`;
              break;
            }
            this.deps.showView(view);
            ok = true;
            detail = `vista abierta: ${view}`;
            break;
          }
          case 'focus_session': {
            const sessionId = args.session_id ?? '';
            if (!sessionId || !/^\d+$/.test(sessionId)) {
              detail = 'session_id inválido';
              break;
            }
            this.deps.focusSession(sessionId);
            ok = true;
            detail = `sesión enfocada: ${sessionId}`;
            break;
          }
          case 'open_window': {
            const vista = String(args.vista ?? args.view ?? '');
            if (!SECONDARY_VIEWS.has(vista)) {
              detail = `vista de ventana desconocida: ${vista || '(vacía)'}`;
              break;
            }
            const req: { vista: string; path?: string; order_id?: number } = { vista };
            if (typeof args.path === 'string' && args.path) req.path = args.path;
            const oid = Number(args.order_id ?? args.orderId ?? 0);
            if (vista === 'preview') {
              const rawOrderId = args.order_id ?? args.orderId;
              if (typeof rawOrderId !== 'number' || !Number.isSafeInteger(rawOrderId) || rawOrderId <= 0) {
                detail = 'Vista previa requiere order_id entero positivo.';
                break;
              }
              req.path = relativePreviewPath(args.path || 'index.html');
            }
            if (Number.isFinite(oid) && oid > 0) req.order_id = oid;
            const res = await this.deps.openWindow(req);
            ok = true;
            detail = `ventana abierta: ${vista}` + (res?.window_id ? ` (#${res.window_id})` : '');
            break;
          }
          case 'notify': {
            const text = args.text ?? '';
            if (!text) {
              detail = 'texto vacío';
              break;
            }
            notice(text, 'info', 6000);
            ok = true;
            detail = 'notificación mostrada';
            break;
          }
        }
      } catch (e) {
        detail = `error aplicando: ${String(e)}`;
      }
    }

    try {
      await this.core.uiActionAck(eventId, ok, detail);
    } catch {
      // El ack es cortesía del loop; si el bridge falla, no bloqueamos la UI.
    }
    if (!ok) notice(`Acción de agente rechazada — ${detail}`, 'info', 4000);
  }
}
