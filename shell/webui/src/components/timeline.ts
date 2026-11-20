import { html, setHtml } from '../design/html';
import { OrderEvent, eventPayload } from '../bridge/core_api';

/**
 * Timeline de actividad del agente.
 *
 * Renderiza los `OrderEvent` que llegan del motor (core.order.events) como
 * una lista vertical conectada por una linea izquierda, un punto coloreado
 * segun severidad y la hora del evento. Es la vista de "actividad real":
 * cada fila viene del motor, no de texto inventado en el cliente.
 */

export type TimelineSeverity = 'success' | 'warning' | 'danger' | 'accent';

const DANGER_KINDS = ['fail', 'error', 'cancel', 'timeout'];
const WARNING_KINDS = ['approval', 'warn', 'blocked'];
const SUCCESS_KINDS = ['done', 'success', 'verified', 'approved', 'passed'];

/**
 * Kinds que llegan en ráfaga (streaming). Cientos de eventos consecutivos del
 * mismo kind no son cientos de hechos: son UN hecho contado por trozos, la
 * misma regla de correlación que aplica chat_activity en la conversación.
 * Se plegan en una sola fila con contador — la traza completa sigue
 * existiendo en el panel inferior «Salida del motor».
 */
const STREAM_KINDS = new Set([
  'content_delta',
  'worker_output',
  'subagent_stream_chunk',
  'reasoning_delta',
]);



function severityFor(kind: string): TimelineSeverity {
  const k = kind.toLowerCase();
  if (DANGER_KINDS.some((s) => k.includes(s))) return 'danger';
  if (WARNING_KINDS.some((s) => k.includes(s))) return 'warning';
  if (SUCCESS_KINDS.some((s) => k.includes(s))) return 'success';
  return 'accent';
}

function formatTime(ts: number): string {
  if (!ts) return '--:--';
  const ms = ts > 1e12 ? ts : ts * 1000;
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return '--:--';
  return d.toLocaleTimeString('es-ES', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

/**
 * Texto legible del evento. El payload llega YA ANIDADO como objeto desde el
 * motor; leerlo como cadena JSON dejaba la linea de tiempo sin un solo detalle.
 */
function describePayload(ev: OrderEvent): string {
  const p = eventPayload(ev);
  for (const key of ['text', 'message', 'summary', 'description', 'file', 'path', 'error']) {
    const v = p[key];
    if (typeof v === 'string' && v.trim()) return v.trim();
  }
  return '';
}

function kindLabel(kind: string): string {
  return kind.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
}

/** Una fila pintada: el último evento del grupo + cuántos se plegaron en él. */
interface Row {
  key: string;
  ev: OrderEvent;
  count: number;
  el: HTMLElement;
}

export class Timeline {
  private container: HTMLElement;
  private listEl!: HTMLElement;
  private events: OrderEvent[] = [];
  private rows: Row[] = [];

  /** la colección es solo bookkeeping de las filas plegadas; sin cota,
   *  una orden larga (miles de deltas) la inflaba hasta agotar el heap del
   *  renderer y la ventana quedaba en blanco. Las filas DOM ya están
   *  plegadas por STREAM_KINDS — aquí basta conservar la cola. */
  private static readonly EVENT_CAP = 6000;

  constructor(container: HTMLElement) {
    this.container = container;
    this.render();
  }

  public setEvents(events: OrderEvent[]): void {
    this.events = [...events];
    this.renderList();
  }

  public addEvent(event: OrderEvent): void {
    this.events.push(event);
    if (this.events.length > Timeline.EVENT_CAP) {
      this.events.splice(0, this.events.length - Timeline.EVENT_CAP);
    }
    // Incremental: antes se re-renderizaban TODAS las filas por cada evento
    // (O(n²) — con ráfagas de streaming el panel estaba permanentemente
    // ocupado reescribiendo su DOM y ni el scroll ni el <details> parecían
    // responder). Ahora cada evento añade una fila o actualiza la última.
    const last = this.rows[this.rows.length - 1];
    const key = this.groupKey(event);
    if (last && key && last.key === key) {
      last.ev = event;
      last.count += 1;
      this.paintRow(last);
      return;
    }
    this.appendRow(key || `ev:${this.events.length}:${event.kind ?? ''}`, event);
  }

  public clear(): void {
    this.events = [];
    this.rows = [];
    this.renderList();
  }

  /**
   * Clave de plegado: solo los kinds de ráfaga se agrupan, y además por
   * task_id cuando lo traen — la salida de dos tareas paralelas no se mezcla.
   * El resto de eventos son uno por fila, como siempre.
   */
  private groupKey(ev: OrderEvent): string {
    const kind = String(ev.kind ?? '');
    if (!STREAM_KINDS.has(kind)) return '';
    const p = eventPayload(ev);
    return `${kind}:${String(p.task_id ?? p.task ?? '')}`;
  }

  private render(): void {
    this.container.innerHTML = `<div class="col" style="gap:0;"></div>`;
    this.listEl = this.container.firstElementChild as HTMLElement;
  }

  private appendRow(key: string, ev: OrderEvent): void {
    const el = document.createElement('div');
    const row: Row = { key, ev, count: 1, el };
    this.paintRow(row);
    this.rows.push(row);
    this.listEl.appendChild(el);
    this.listEl.style.display = 'flex';
  }

  private paintRow(row: Row): void {
    const ev = row.ev;
    const severity = severityFor(ev.kind || '');
    const detail = describePayload(ev);
    const label = kindLabel(ev.kind || 'evento');
    const count = row.count > 1 ? html`<span style="font-size:10px;color:var(--fg-subtle);flex:0 0 auto">×${row.count}</span>` : '';
    row.el.style.cssText = 'position:relative; padding:2px 0 10px 16px; border-left:1px solid var(--border);';
    setHtml(row.el, html`
      <span style="position:absolute; left:-4px; top:5px; width:8px; height:8px; border-radius:50%; background:var(--${severity});"></span>
      <div class="row" style="justify-content:space-between; gap:8px;">
        <span style="font-size:11px; font-weight:600; color:var(--fg-muted);">${label}</span>
        <span class="row" style="gap:6px;flex:0 0 auto">${count}<span style="font-size:10px; color:var(--fg-subtle);">${formatTime(ev.ts)}</span></span>
      </div>
      ${detail ? html`<div class="subtle" style="font-size:11px; margin-top:2px; word-break:break-word;">${detail}</div>` : ''}
      ${ev.source ? html`<div style="font-size:10px; color:var(--fg-subtle); margin-top:1px;">${ev.source}</div>` : ''}
    `);
  }

  private renderList(): void {
    if (!this.listEl) return;
    this.rows = [];
    this.listEl.innerHTML = '';

    if (this.events.length === 0) {
      this.listEl.style.display = 'none';
      return;
    }
    this.listEl.style.display = 'flex';
    for (const ev of this.events) {
      const last = this.rows[this.rows.length - 1];
      const key = this.groupKey(ev);
      if (last && key && last.key === key) {
        last.ev = ev;
        last.count += 1;
        this.paintRow(last);
      } else {
        this.appendRow(key || `ev:${this.rows.length}:${ev.kind ?? ''}`, ev);
      }
    }
  }
}
