/**
 * — avisos que sirven.
 *
 * Una orden tiene cuatro momentos en los que el usuario tiene que saberlo aunque
 * esté mirando otra cosa: terminó, falló, pide aprobación del plan o hace una
 * pregunta (aclaración). Este módulo detecta esos cuatro a partir de la lista
 * de sesiones del motor (`core.sessions.list`: id de orden + estado), avisa una
 * sola vez por orden y evento, y los deja en una bandeja de no leídos que abre
 * la orden exacta.
 *
 * Por qué la lista de sesiones y no la fase de MissionControlPanel: la fase solo
 * existe para la orden abierta, y una orden que termina o pregunta mientras el
 * usuario mira otra (o lanzada desde otra IDE por MCP) es justo la que hay que
 * avisar. El estado del motor es la única fuente que las ve todas.
 *
 * SEGURIDAD: títulos de orden y textos del modelo van siempre por `textContent`;
 * nunca por innerHTML.
 *
 * LÍMITE DEL HOST: la cabina deniega TODOS los permisos de WebView2
 * (shell/host/webview_host.cpp: PermissionRequested -> Deny), notificaciones
 * incluidas. La notificación nativa solo se emite si `Notification.permission`
 * ya es 'granted' (nunca se pide); con el host actual no lo es y queda el toast.
 */
import { orderStatusKey } from '../design/status_labels';
import { clearAlert } from '../design/alerts';

export type AttentionEvent = 'done' | 'failed' | 'approval' | 'question';

export interface AttentionItem {
  /** `${orderId}:${event}`: un aviso por evento y orden. */
  key: string;
  orderId: number;
  conversationId: string | null;
  event: AttentionEvent;
  title: string;
  /** Milisegundos desde epoch. */
  at: number;
  read: boolean;
  /** Cola del motor: transitoria, permanece pendiente hasta resolverse. */
  approvalId?: number;
}

export interface SessionLike {
  id?: number;
  order_id?: number;
  conversation_id?: string | null;
  title?: string;
  status?: string | number;
  status_text?: string;
}

/** Textos por evento: `short` para la etiqueta de la bandeja, `verb` para el aviso. */
export const EVENT_TEXT: Record<AttentionEvent, { short: string; verb: string }> = {
  done: { short: 'Terminó', verb: 'terminó' },
  failed: { short: 'Falló', verb: 'falló' },
  approval: { short: 'Pide aprobación', verb: 'pide aprobación' },
  question: { short: 'Pregunta', verb: 'te hace una pregunta' },
};

/** Evento que corresponde a un estado de orden, o null si no es ninguno de los cuatro. */
export function eventForStatus(status: string | number | null | undefined): AttentionEvent | null {
  switch (orderStatusKey(status)) {
    case 'done':
      return 'done';
    case 'failed':
      return 'failed';
    case 'planned':
    case 'awaiting_approval':
      return 'approval';
    case 'clarifying':
      return 'question';
    default:
      return null;
  }
}

const STORAGE_KEY = 'devagents.attention.v1';
const MAX_ITEMS = 50;

interface Persisted {
  items: AttentionItem[];
  native: boolean;
}

export interface NotificationLike {
  permission: string;
}
type NotificationCtor = (new (title: string, options?: { body?: string; tag?: string }) => {
  onclick: ((ev: unknown) => void) | null;
  close(): void;
}) &
  NotificationLike;

export interface AttentionDeps {
  /** Devuelve el almacenamiento; puede lanzar (modo privado, denegado). */
  storage?: () => Pick<Storage, 'getItem' | 'setItem'>;
  now?: () => number;
  /** true si la ventana tiene el foco. */
  isFocused?: () => boolean;
  /** Constructor Notification del WebView, o null si no existe. */
  notification?: () => NotificationCtor | null;
  /** Abre la orden. Devuelve false si no se pudo (p. ej. hay otra en curso). */
  openOrder: (orderId: number, conversationId: string | null) => boolean | Promise<boolean>;
  openApproval?: (approvalId: number) => boolean | Promise<boolean>;
  onError?: (message: string) => void;
}

export class AttentionCenter {
  private items: AttentionItem[] = [];
  private approvals: AttentionItem[] = [];
  private approvalError = '';
  private nativeOn = true;
  private primed = false;
  private lastEvent = new Map<number, AttentionEvent | null>();
  private listeners: Array<() => void> = [];
  private toastHost: HTMLElement | null = null;
  private storageWarned = false;

  constructor(private readonly deps: AttentionDeps) {
    this.load();
  }

  // --- Estado ---------------------------------------------------------------

  public list(): readonly AttentionItem[] {
    return [...this.approvals, ...this.items];
  }

  public unreadCount(): number {
    return this.list().filter((i) => !i.read).length;
  }

  public approvalsUnavailable(message: string): void {
    this.approvalError = message;
    this.emit();
  }

  public approvalsError(): string { return this.approvalError; }

  /** Incluye la cola ya pendiente al arrancar, sin inventar transiciones. */
  public observeApprovals(rows: readonly unknown[]): void {
    const previous = new Map(this.approvals.map(item => [item.key, item]));
    const pending = new Map<string, AttentionItem>();
    for (const raw of rows) {
      if (!raw || typeof raw !== 'object') continue;
      const row = raw as Record<string, unknown>;
      const id = Number(row.id ?? row.approval_id);
      if (!Number.isSafeInteger(id) || id <= 0) continue;
      const key = `engine-approval:${id}`;
      const order = Number(row.order_id);
      pending.set(key, {
        key, approvalId: id, orderId: Number.isSafeInteger(order) && order > 0 ? order : 0,
        conversationId: null, event: 'approval', read: false,
        title: String(row.description ?? row.command_prefix ?? row.task_id ?? 'Solicitud del motor'),
        at: previous.get(key)?.at ?? (this.deps.now ?? Date.now)(),
      });
    }
    this.approvals = [...pending.values()];
    this.approvalError = '';
    this.emit();
  }

  public onChange(fn: () => void): void {
    this.listeners.push(fn);
  }

  public nativeEnabled(): boolean {
    return this.nativeOn;
  }

  /** La notificación del sistema solo es posible si el host ya concedió el permiso. */
  public nativeAvailable(): boolean {
    const N = this.deps.notification ? this.deps.notification() : this.defaultNotification();
    return !!N && N.permission === 'granted';
  }

  public setNativeEnabled(value: boolean): void {
    this.nativeOn = value;
    this.save();
    this.emit();
  }

  public markRead(key: string): void {
    const item = this.items.find((i) => i.key === key);
    if (!item || item.read) return;
    item.read = true;
    this.save();
    this.emit();
    clearAlert(`attention:${key}`);
  }

  public markAllRead(): void {
    let changed = false;
    for (const i of this.items) if (!i.read) { i.read = true; changed = true; }
    if (changed) { this.save(); this.emit(); }
  }

  /** Abre la orden del aviso y, solo si se abrió, lo marca leído. */
  public async open(key: string): Promise<boolean> {
    const item = this.list().find((i) => i.key === key);
    if (!item) return false;
    let ok = false;
    try {
      ok = item.approvalId !== undefined
        ? await this.deps.openApproval?.(item.approvalId) ?? false
        : await this.deps.openOrder(item.orderId, item.conversationId);
    } catch (error) {
      this.deps.onError?.(String(error));
    }
    if (ok && item.approvalId === undefined) {
      this.markRead(key);
      clearAlert(`attention:${key}`);
    }
    return ok;
  }

  // --- Detección ------------------------------------------------------------

  /**
   * Compara la lista de sesiones con la anterior. La PRIMERA lectura solo fija
   * la línea base: lo que ya estaba pendiente al arrancar no se avisa de golpe.
   * Después, cada orden que entra en uno de los cuatro estados avisa una vez;
   * volver a leer el mismo estado (el sondeo repite) no avisa otra vez, y una
   * clave ya guardada (también de una sesión anterior) tampoco.
   */
  public observe(sessions: readonly SessionLike[]): void {
    const fresh: AttentionItem[] = [];
    for (const s of sessions) {
      const orderId = Number(s.order_id ?? s.id ?? 0);
      if (!orderId) continue;
      const event = eventForStatus(s.status_text ?? s.status);
      const previous = this.lastEvent.get(orderId);
      this.lastEvent.set(orderId, event);
      if (!this.primed || !event || previous === event) continue;
      const key = `${orderId}:${event}`;
      if (this.items.some((i) => i.key === key)) continue;
      fresh.push({
        key,
        orderId,
        conversationId: s.conversation_id ?? null,
        event,
        title: String(s.title ?? '').trim(),
        at: (this.deps.now ?? Date.now)(),
        read: false,
      });
    }
    this.primed = true;
    if (!fresh.length) return;
    this.items = [...fresh.reverse(), ...this.items].slice(0, MAX_ITEMS);
    this.save();
    for (const item of fresh) {
      // 8-nov (propietario): un aviso por cada orden terminada «no es debido, ni
      // común ni lo estándar». Terminar solo avisa si el usuario lo activa en
      // Configuración › Avisos; fallos, aprobaciones y preguntas, siempre.
      // Todo queda igualmente en la lista de la campana.
      if (item.event === 'done' && !this.notifyDone()) continue;
      // 11-nov (propietario): el fallo de UNA orden no es un aviso de sistema. Ya
      // se ve en el chat y queda en la campana; sin toast dentro de la cabina
      // ni punto en la esquina (esa es para modelos, proveedores y modos).
      // Fuera de foco sí sale la notificación del sistema, como en el mercado.
      if (item.event !== 'failed') this.toast(item);
      this.systemNotify(item);
    }
    this.emit();
  }

  // --- Avisos ---------------------------------------------------------------

  private message(item: AttentionItem): string {
    return `Orden #${item.orderId} ${EVENT_TEXT[item.event].verb}`;
  }

  /** Toast accesible: `alert` para el fallo, `status` para el resto. */
  private toast(item: AttentionItem): void {
    if (typeof document === 'undefined') return;
    if (!this.toastHost || !this.toastHost.isConnected) {
      const host = document.createElement('div');
      host.id = 'attention-toasts';
      host.className = 'attn-toasts';
      document.body.appendChild(host);
      this.toastHost = host;
    }
    const card = document.createElement('div');
    card.className = `attn-toast attn-toast--${item.event}`;
    card.setAttribute('role', item.event === 'failed' ? 'alert' : 'status');
    card.dataset.order = String(item.orderId);
    card.dataset.event = item.event;
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'attn-toast__open';
    const head = document.createElement('strong');
    head.textContent = this.message(item);
    open.appendChild(head);
    if (item.title) {
      const sub = document.createElement('span');
      sub.textContent = item.title;
      open.appendChild(sub);
    }
    open.addEventListener('click', () => { void this.open(item.key); card.remove(); });
    // El toast es pasajero; lo que no se leyó sigue en la campana.
    const fold = (): void => { if (card.isConnected) card.remove(); };
    const close = document.createElement('button');
    close.type = 'button';
    close.className = 'attn-toast__close';
    close.setAttribute('aria-label', 'Descartar aviso');
    close.textContent = '×';
    close.addEventListener('click', fold);
    card.append(open, close);
    this.toastHost.appendChild(card);
    while (this.toastHost.childElementCount > 4) this.toastHost.firstElementChild?.remove();
    window.setTimeout(fold, 10000);
  }

  private isRead(key: string): boolean {
    return this.items.some((i) => i.key === key && i.read);
  }

  private defaultNotification(): NotificationCtor | null {
    return typeof Notification === 'undefined' ? null : (Notification as unknown as NotificationCtor);
  }

  /** Notificación del sistema: solo sin foco, si el usuario no la apagó y el host la permite. */
  private systemNotify(item: AttentionItem): void {
    if (!this.nativeOn) return;
    const focused = this.deps.isFocused ? this.deps.isFocused() : typeof document !== 'undefined' && document.hasFocus();
    if (focused) return;
    const N = this.deps.notification ? this.deps.notification() : this.defaultNotification();
    if (!N || N.permission !== 'granted') return;
    try {
      const n = new N(this.message(item), { body: item.title, tag: item.key });
      n.onclick = () => {
        try { window.focus(); } catch { /* sin foco programático */ }
        void this.open(item.key);
        n.close();
      };
    } catch (error) {
      this.deps.onError?.(`No se pudo mostrar la notificación del sistema: ${String(error)}`);
    }
  }

  // --- Persistencia ---------------------------------------------------------

  /** «Avisar cuando termine cada orden»: apagado salvo que se active. */
  private notifyDone(): boolean {
    try {
      return this.store()?.getItem(NOTIFY_DONE_KEY) === '1';
    } catch {
      return false;
    }
  }

  private store(): Pick<Storage, 'getItem' | 'setItem'> | null {
    try {
      return this.deps.storage ? this.deps.storage() : window.localStorage;
    } catch (error) {
      if (!this.storageWarned) {
        this.storageWarned = true;
        this.deps.onError?.(`Los avisos no se guardarán entre sesiones: ${String(error)}`);
      }
      return null;
    }
  }

  private load(): void {
    try {
      const raw = this.store()?.getItem(STORAGE_KEY);
      if (!raw) return;
      const data = JSON.parse(raw) as Partial<Persisted>;
      if (Array.isArray(data.items)) {
        this.items = data.items
          .filter((i) => i && typeof i.key === 'string' && Number.isFinite(i.orderId) && i.event in EVENT_TEXT)
          .map((i) => ({
            key: i.key, orderId: Number(i.orderId), conversationId: i.conversationId ?? null, event: i.event,
            title: String(i.title ?? ''), at: Number(i.at) || 0, read: !!i.read,
          }))
          .slice(0, MAX_ITEMS);
      }
      if (typeof data.native === 'boolean') this.nativeOn = data.native;
    } catch (error) {
      this.deps.onError?.(`No se pudieron leer los avisos guardados: ${String(error)}`);
    }
  }

  private save(): void {
    try {
      this.store()?.setItem(STORAGE_KEY, JSON.stringify({ items: this.items, native: this.nativeOn } satisfies Persisted));
    } catch (error) {
      this.deps.onError?.(`No se pudieron guardar los avisos: ${String(error)}`);
    }
  }

  private emit(): void {
    for (const fn of this.listeners) fn();
  }
}

/**
 * Bandeja de no leídos: botón con contador en la barra de título y panel con la
 * lista (orden, tipo, hora). Pulsar una fila abre la orden exacta y la marca
 * leída. Las solicitudes de la cola del motor permanecen pendientes hasta
 * resolverse en Monitor. El interruptor de notificaciones del sistema vive aquí: Configuración
 * no tiene una sección de avisos a la que pertenezca de forma natural.
 */
export class AttentionTray {
  private readonly button: HTMLButtonElement;
  private readonly badge: HTMLElement;
  private readonly panel: HTMLElement;
  private readonly list: HTMLElement;
  private readonly nativeBox: HTMLInputElement;
  private readonly nativeHint: HTMLElement;
  private readonly readAll: HTMLButtonElement;

  constructor(private readonly center: AttentionCenter, button: HTMLButtonElement) {
    this.button = button;
    this.button.setAttribute('aria-haspopup', 'dialog');
    this.button.setAttribute('aria-expanded', 'false');
    this.button.setAttribute('aria-controls', 'attention-tray');
    this.badge = document.createElement('span');
    this.badge.id = 'attention-count';
    this.badge.className = 'attn-badge';
    this.badge.hidden = true;
    this.button.appendChild(this.badge);

    this.panel = document.createElement('div');
    this.panel.id = 'attention-tray';
    this.panel.className = 'attn-tray';
    this.panel.setAttribute('role', 'dialog');
    this.panel.setAttribute('aria-label', 'Avisos de órdenes');
    this.panel.hidden = true;

    const head = document.createElement('div');
    head.className = 'attn-tray__head';
    const title = document.createElement('strong');
    title.textContent = 'Avisos';
    this.readAll = document.createElement('button');
    this.readAll.type = 'button';
    this.readAll.id = 'attention-read-all';
    this.readAll.className = 'btn btn--sm btn--ghost';
    this.readAll.textContent = 'Marcar todo como leído';
    this.readAll.addEventListener('click', () => this.center.markAllRead());
    head.append(title, this.readAll);

    this.list = document.createElement('ul');
    this.list.id = 'attention-list';
    this.list.className = 'attn-list';

    const foot = document.createElement('div');
    foot.className = 'attn-tray__foot';
    const label = document.createElement('label');
    this.nativeBox = document.createElement('input');
    this.nativeBox.type = 'checkbox';
    this.nativeBox.id = 'attention-native';
    this.nativeBox.addEventListener('change', () => this.center.setNativeEnabled(this.nativeBox.checked));
    label.append(this.nativeBox, document.createTextNode(' Notificaciones del sistema (con la ventana sin foco)'));
    this.nativeHint = document.createElement('span');
    this.nativeHint.id = 'attention-native-hint';
    this.nativeHint.className = 'attn-tray__hint';
    foot.append(label, this.nativeHint);

    this.panel.append(head, this.list, foot);
    document.body.appendChild(this.panel);

    this.button.addEventListener('click', () => this.toggle());
    document.addEventListener('keydown', (ev) => {
      if (ev.key === 'Escape' && !this.panel.hidden) { this.toggle(false); this.button.focus(); }
    });
    document.addEventListener('mousedown', (ev) => {
      const t = ev.target as Node;
      if (!this.panel.hidden && !this.panel.contains(t) && !this.button.contains(t)) this.toggle(false);
    });
    this.center.onChange(() => this.render());
    this.render();
  }

  public toggle(open?: boolean): void {
    const next = open ?? this.panel.hidden;
    this.panel.hidden = !next;
    this.button.setAttribute('aria-expanded', String(next));
    if (next) this.render();
  }

  private render(): void {
    const unread = this.center.unreadCount();
    const pending = this.center.list().filter(item => item.approvalId !== undefined).length;
    const unreadNotices = unread - pending;
    this.badge.textContent = String(unread);
    this.badge.hidden = unread === 0;
    const label = (pending
      ? `Avisos: ${pending} aprobaciones pendientes${unreadNotices ? ` y ${unreadNotices} sin leer` : ''}`
      : unread ? `Avisos: ${unread} sin leer` : 'Avisos: nada sin leer') +
      (this.center.approvalsError() ? '; aprobaciones sin verificar' : '');
    this.button.setAttribute('aria-label', label);
    this.button.title = label;
    this.readAll.disabled = unreadNotices === 0;

    this.nativeBox.checked = this.center.nativeEnabled();
    const available = this.center.nativeAvailable();
    this.nativeBox.disabled = !available;
    this.nativeHint.textContent = available ? '' : 'Este equipo no concede notificaciones del sistema a la cabina; los avisos salen solo dentro de ella.';

    this.list.replaceChildren();
    const approvalError = this.center.approvalsError();
    if (approvalError) {
      const error = document.createElement('li');
      error.setAttribute('role', 'alert');
      error.textContent = `Aprobaciones sin verificar: ${approvalError}`;
      this.list.appendChild(error);
    }
    const items = this.center.list();
    if (!items.length) {
      const empty = document.createElement('li');
      empty.className = 'attn-empty';
      empty.textContent = approvalError ? 'La cola del motor no está disponible.' : 'Sin avisos. Aquí aparecerán las órdenes que terminan, fallan, piden aprobación o preguntan.';
      this.list.appendChild(empty);
      return;
    }
    for (const item of items) {
      const li = document.createElement('li');
      const row = document.createElement('button');
      row.type = 'button';
      row.className = 'attn-item';
      row.dataset.key = item.key;
      row.dataset.order = String(item.orderId);
      row.dataset.event = item.event;
      row.dataset.read = String(item.read);
      const what = document.createElement('span');
      what.className = 'attn-item__what';
      what.textContent = item.approvalId !== undefined
        ? `${item.orderId ? `Orden #${item.orderId} · ` : ''}Solicitud #${item.approvalId} · Resolver aprobación`
        : `Orden #${item.orderId} · ${EVENT_TEXT[item.event].short}`;
      const sub = document.createElement('span');
      sub.className = 'attn-item__sub';
      const time = document.createElement('time');
      time.dateTime = new Date(item.at).toISOString();
      time.textContent = new Date(item.at).toLocaleTimeString('es', { hour: '2-digit', minute: '2-digit' });
      sub.append(time, document.createTextNode(item.title ? ` · ${item.title}` : ''));
      row.append(what, sub);
      row.addEventListener('click', () => {
        void this.center.open(item.key).then((ok) => { if (ok) this.toggle(false); });
      });
      li.appendChild(row);
      this.list.appendChild(li);
    }
  }
}

/** Clave del ajuste «Avisar cuando termine cada orden» (Configuración › Avisos). */
export const NOTIFY_DONE_KEY = 'devagents.notify.done.v1';

/** Apagado por defecto (8-nov, propietario): solo avisa si el usuario lo activó. */
export function notifyDoneEnabled(): boolean {
  try {
    return typeof localStorage !== 'undefined' && localStorage.getItem(NOTIFY_DONE_KEY) === '1';
  } catch {
    return false;
  }
}
