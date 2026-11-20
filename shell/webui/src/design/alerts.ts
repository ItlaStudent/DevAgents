/**
 * Alertas persistentes que se pliegan en un punto «!» (propietario, 10-nov).
 *
 * Los avisos de configuración y de modelos se escribían en naranja DEBAJO del
 * compositor y el aviso de «no hay modelos» ocupaba una franja arriba. Ahora
 * todo vive abajo a la derecha:
 *
 * - Hay como mucho DOS botones, uno por color: rojo (FALLO) y ámbar (AVISO).
 *   Si hay alertas de ambos colores sin revisar, se ven los dos. Varias del
 *   mismo color se AGRUPAN en su botón, que muestra cuántas son.
 * - Al llegar una alerta, la tarjeta de su color se abre unos segundos y luego
 *   se pliega en el botón. Pasar el ratón o pulsarlo la abre con una animación
 *   leve que nace del propio botón; al salir se vuelve a plegar (si se abrió
 *   con un clic, se queda abierta hasta pulsar fuera, Esc o la ×).
 * - Un FALLO no desaparece hasta que el usuario lo marca como leído
 *   («Entendido»). Un AVISO también se puede descartar, y además lo retira
 *   quien lo emitió en cuanto la condición deja de darse (`clearAlert`).
 * - Mismo `id` con el mismo texto no vuelve a molestar; si el texto cambia,
 *   la alerta vuelve a abrirse.
 *
 * Estilos en línea con los tokens del tema (mismo criterio que notice.ts).
 */

export type AlertLevel = 'warn' | 'error';

export interface AlertAction {
  label: string;
  run: () => void;
}

export interface AlertSpec {
  id: string;
  level: AlertLevel;
  title: string;
  body?: string;
  actions?: AlertAction[];
  /** Nace ya plegada en el botón (p. ej. tras un toast que el usuario ya vio). */
  startCollapsed?: boolean;
}

interface AlertItem extends AlertSpec {
  signature: string;
  unread: boolean;
}

interface Group {
  level: AlertLevel;
  el: HTMLElement;
  card: HTMLElement;
  list: HTMLElement;
  dot: HTMLButtonElement;
  count: HTMLElement;
  pinned: boolean;
  collapseTimer: number | null;
}

const DOCK_ID = 'devagents-alerts';
/** Tiempo que la tarjeta se ve abierta al llegar algo nuevo antes de plegarse. */
export const ALERT_AUTO_COLLAPSE_MS = 7000;
const items = new Map<string, AlertItem>();
const groups = new Map<AlertLevel, Group>();
/** Alertas descartadas por el usuario: no vuelven mientras el texto sea igual. */
const dismissed = new Map<string, string>();

function colorFor(level: AlertLevel): string {
  return level === 'error' ? 'var(--danger)' : 'var(--warning)';
}

function dock(): HTMLElement {
  let el = document.getElementById(DOCK_ID);
  if (el) return el;
  el = document.createElement('div');
  el.id = DOCK_ID;
  el.setAttribute('role', 'region');
  el.setAttribute('aria-label', 'Avisos y fallos');
  // row-reverse: el primero en el DOM (rojo) queda en la esquina.
  el.style.cssText = [
    // Con el navegador integrado abierto, la esquina es la de la zona de
    // trabajo: encima de la página nativa no se vería (y la taparía).
    'position:fixed', 'right:calc(var(--browser-w, 0px) + 16px)', 'bottom:40px', 'z-index:9001',
    'display:flex', 'flex-direction:row-reverse', 'align-items:flex-end', 'gap:8px',
    'pointer-events:none',
  ].join(';');
  document.body.appendChild(el);
  if (!document.getElementById('devagents-alerts-style')) {
    const style = document.createElement('style');
    style.id = 'devagents-alerts-style';
    style.textContent = `
      @keyframes devagents-alert-pulse { 0%,100% { box-shadow:0 0 0 0 var(--alert-ring); } 50% { box-shadow:0 0 0 5px transparent; } }
      #${DOCK_ID} .da-alert-dot[data-unread="1"] { animation: devagents-alert-pulse 2.2s ease-in-out infinite; }
      @media (prefers-reduced-motion: reduce) {
        #${DOCK_ID} .da-alert-dot[data-unread="1"] { animation: none; }
        #${DOCK_ID} .da-alert-card { transition: none !important; }
      }`;
    document.head.appendChild(style);
  }
  return el;
}

function signatureOf(spec: AlertSpec): string {
  return `${spec.level}\u0001${spec.title}\u0001${spec.body ?? ''}`;
}

function setOpen(group: Group, open: boolean): void {
  const c = group.card;
  c.style.visibility = open ? 'visible' : 'hidden';
  c.style.opacity = open ? '1' : '0';
  c.style.transform = open ? 'scale(1)' : 'scale(0.15)';
  c.style.pointerEvents = open ? 'auto' : 'none';
  group.el.dataset.open = open ? '1' : '0';
  if (open) {
    for (const it of items.values()) if (it.level === group.level) it.unread = false;
    group.dot.dataset.unread = '0';
  }
}

function scheduleCollapse(group: Group, ms: number): void {
  if (group.collapseTimer !== null) window.clearTimeout(group.collapseTimer);
  group.collapseTimer = window.setTimeout(() => {
    group.collapseTimer = null;
    if (!group.pinned) setOpen(group, false);
  }, ms);
}

function levelItems(level: AlertLevel): AlertItem[] {
  return [...items.values()].filter((it) => it.level === level);
}

function buildGroup(level: AlertLevel): Group {
  const el = document.createElement('div');
  el.className = 'da-alert';
  el.dataset.level = level;
  el.style.cssText = 'position:relative;pointer-events:auto;width:26px;height:26px';
  const dot = document.createElement('button');
  dot.type = 'button';
  dot.className = 'da-alert-dot';
  dot.textContent = '!';
  dot.style.cssText = `position:relative;width:26px;height:26px;border-radius:50%;border:none;color:#111;font-weight:800;font-size:14px;line-height:26px;padding:0;cursor:pointer;box-shadow:0 2px 8px rgba(0,0,0,.4);background:${colorFor(level)}`;
  dot.style.setProperty('--alert-ring', level === 'error' ? 'rgba(220,60,60,.45)' : 'rgba(230,170,40,.45)');
  const count = document.createElement('span');
  count.className = 'da-alert-count';
  count.style.cssText = 'position:absolute;top:-6px;right:-6px;min-width:15px;height:15px;padding:0 3px;box-sizing:border-box;border-radius:8px;background:var(--bg-elevated, var(--bg-panel));color:var(--text);border:1px solid var(--border);font-size:10px;font-weight:700;line-height:13px;text-align:center';
  dot.appendChild(count);
  const card = document.createElement('div');
  card.className = 'da-alert-card';
  card.setAttribute('role', level === 'error' ? 'alert' : 'status');
  card.style.cssText = [
    'position:absolute', 'right:0', 'bottom:34px', 'width:min(380px, calc(100vw - 32px))', 'box-sizing:border-box',
    'max-height:min(60vh, 520px)', 'overflow-y:auto',
    'padding:10px 12px', 'border-radius:8px', 'border:1px solid var(--border)', `border-left:3px solid ${colorFor(level)}`,
    'background:var(--bg-elevated, var(--bg-panel))', 'color:var(--text)', 'font-size:12px', 'line-height:1.45',
    'box-shadow:0 8px 24px rgba(0,0,0,.4)', 'transform-origin:bottom right',
    'transition:opacity .16s ease, transform .18s cubic-bezier(.2,.8,.2,1), visibility .18s',
  ].join(';');
  const head = document.createElement('div');
  head.style.cssText = 'display:flex;align-items:center;gap:8px;margin-bottom:4px';
  const badge = document.createElement('span');
  badge.className = 'da-alert-heading';
  badge.style.cssText = `flex:1;font-size:10px;font-weight:700;letter-spacing:.04em;text-transform:uppercase;color:${colorFor(level)}`;
  const close = document.createElement('button');
  close.type = 'button';
  close.textContent = '×';
  close.title = 'Cerrar (sigue en el botón hasta marcarlo como leído)';
  close.setAttribute('aria-label', 'Cerrar');
  close.style.cssText = 'flex:none;background:transparent;border:none;color:var(--fg-muted, var(--text));font-size:15px;line-height:1;cursor:pointer;padding:0 2px';
  head.append(badge, close);
  const list = document.createElement('div');
  list.className = 'da-alert-list';
  card.append(head, list);
  el.append(card, dot);
  const group: Group = { level, el, card, list, dot, count, pinned: false, collapseTimer: null };
  close.addEventListener('click', (e) => { e.stopPropagation(); group.pinned = false; setOpen(group, false); });
  el.addEventListener('mouseenter', () => {
    if (group.collapseTimer !== null) window.clearTimeout(group.collapseTimer);
    group.collapseTimer = null;
    setOpen(group, true);
  });
  el.addEventListener('mouseleave', () => { if (!group.pinned) scheduleCollapse(group, 500); });
  dot.addEventListener('click', (e) => {
    e.stopPropagation();
    group.pinned = !group.pinned || group.el.dataset.open !== '1';
    setOpen(group, group.pinned);
  });
  setOpen(group, false);
  return group;
}

function renderItem(it: AlertItem): HTMLElement {
  const row = document.createElement('div');
  row.className = 'da-alert-item';
  row.dataset.alertId = it.id;
  row.style.cssText = 'padding:6px 0;border-top:1px solid var(--border)';
  const title = document.createElement('div');
  title.className = 'da-alert-title';
  title.style.cssText = 'font-weight:600';
  // textContent: los textos traen rutas y errores del motor sin sanear.
  title.textContent = it.title;
  row.appendChild(title);
  if (it.body) {
    const body = document.createElement('div');
    body.className = 'da-alert-body';
    body.style.cssText = 'margin-top:3px;color:var(--fg-muted, var(--text));white-space:pre-wrap;word-break:break-word';
    body.textContent = it.body;
    row.appendChild(body);
  }
  const actions = document.createElement('div');
  actions.style.cssText = 'display:flex;flex-wrap:wrap;gap:6px;margin-top:6px;justify-content:flex-end';
  for (const action of it.actions ?? []) {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = 'btn';
    b.textContent = action.label;
    b.addEventListener('click', (e) => { e.stopPropagation(); action.run(); });
    actions.appendChild(b);
  }
  const ok = document.createElement('button');
  ok.type = 'button';
  ok.className = 'btn';
  ok.dataset.alertRead = '';
  ok.textContent = 'Entendido';
  ok.title = it.level === 'error' ? 'Marcar el fallo como leído y quitarlo' : 'Descartar este aviso';
  ok.addEventListener('click', (e) => {
    e.stopPropagation();
    dismissed.set(it.id, it.signature);
    removeItem(it.id);
  });
  actions.appendChild(ok);
  row.appendChild(actions);
  return row;
}

/** Repinta el grupo de un color; lo quita si se quedó vacío. */
function refreshGroup(level: AlertLevel): void {
  const list = levelItems(level);
  let group = groups.get(level);
  if (!list.length) {
    if (group) {
      if (group.collapseTimer !== null) window.clearTimeout(group.collapseTimer);
      groups.delete(level);
      setOpen(group, false);
      const el = group.el;
      window.setTimeout(() => el.remove(), 180);
    }
    return;
  }
  if (!group) {
    group = buildGroup(level);
    groups.set(level, group);
    const host = dock();
    // Rojo siempre en la esquina (primero en el DOM con row-reverse).
    if (level === 'error') host.insertBefore(group.el, host.firstChild);
    else host.appendChild(group.el);
  }
  const n = list.length;
  const noun = level === 'error' ? (n === 1 ? 'Fallo' : 'Fallos') : (n === 1 ? 'Aviso' : 'Avisos');
  (group.card.querySelector('.da-alert-heading') as HTMLElement).textContent = n > 1 ? `${noun} · ${n}` : noun;
  group.count.textContent = n > 1 ? String(n) : '';
  group.count.style.display = n > 1 ? '' : 'none';
  group.dot.title = n > 1 ? `${n} ${noun.toLowerCase()} sin revisar` : `${noun}: ${list[0].title}`;
  group.dot.setAttribute('aria-label', group.dot.title);
  group.dot.dataset.unread = list.some((it) => it.unread) ? '1' : '0';
  group.list.replaceChildren(...list.map(renderItem));
  // La primera fila no necesita separador.
  const first = group.list.firstElementChild as HTMLElement | null;
  if (first) first.style.borderTop = 'none';
}

function removeItem(id: string): void {
  const it = items.get(id);
  if (!it) return;
  items.delete(id);
  refreshGroup(it.level);
}

let globalHandlers = false;
function installGlobalHandlers(): void {
  if (globalHandlers) return;
  globalHandlers = true;
  document.addEventListener('mousedown', (e) => {
    for (const group of groups.values()) {
      if (group.pinned && !group.el.contains(e.target as Node)) { group.pinned = false; setOpen(group, false); }
    }
  }, true);
  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    for (const group of groups.values()) if (group.el.dataset.open === '1') { group.pinned = false; setOpen(group, false); }
  });
}

/** Crea o actualiza una alerta. Mismo id y mismo texto: no hace nada. */
export function raiseAlert(spec: AlertSpec): void {
  if (typeof document === 'undefined' || typeof document.getElementById !== 'function') return;
  const signature = signatureOf(spec);
  if (dismissed.get(spec.id) === signature) return;
  dismissed.delete(spec.id);
  installGlobalHandlers();
  const existing = items.get(spec.id);
  if (existing && existing.signature === signature) {
    existing.actions = spec.actions;
    return;
  }
  const previousLevel = existing?.level;
  items.set(spec.id, { ...spec, signature, unread: true });
  if (previousLevel && previousLevel !== spec.level) refreshGroup(previousLevel);
  refreshGroup(spec.level);
  if (spec.startCollapsed) return;
  const group = groups.get(spec.level)!;
  // Se abre al llegar algo nuevo y se pliega solo.
  requestAnimationFrame(() => setOpen(group, true));
  scheduleCollapse(group, ALERT_AUTO_COLLAPSE_MS);
}

/** Retira una alerta porque su condición ya no se da. */
export function clearAlert(id: string): void {
  dismissed.delete(id);
  removeItem(id);
}

/** Retira todas las alertas cuyo id empieza por `prefix` salvo las de `keep`. */
export function clearAlertsExcept(prefix: string, keep: Set<string>): void {
  for (const id of [...items.keys()]) if (id.startsWith(prefix) && !keep.has(id)) clearAlert(id);
  for (const id of [...dismissed.keys()]) if (id.startsWith(prefix) && !keep.has(id)) dismissed.delete(id);
}

/** Para pruebas y diagnóstico. */
export function activeAlertIds(): string[] {
  return [...items.keys()];
}
