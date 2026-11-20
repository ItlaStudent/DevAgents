/**
 * Avisos transitorios (toasts).
 *
 * La cabina no tenía forma de decirle nada al usuario fuera de un panel: una
 * acción que termina bien no dejaba rastro, y una que fallaba solo se veía si
 * el panel afectado la pintaba. Esto cubre el hueco con lo mínimo.
 *
 * Sin hoja de estilos aparte a propósito: los estilos van en línea y salen de
 * los tokens del tema, así que un tema nuevo no obliga a tocar este archivo y
 * no hay CSS que se quede huérfano si el módulo deja de usarse.
 */

export type NoticeKind = 'info' | 'ok' | 'error';

const CONTAINER_ID = 'beats-notices';
/** Cuántos avisos se ven a la vez. Por encima, se retira el más antiguo. */
const MAX_VISIBLE = 3;

function container(): HTMLElement {
  let el = document.getElementById(CONTAINER_ID);
  if (el) return el;
  el = document.createElement('div');
  el.id = CONTAINER_ID;
  el.setAttribute('role', 'status');
  // aria-live polite: se anuncia sin interrumpir lo que el usuario esté
  // haciendo. assertive robaría el foco del lector de pantalla en cada aviso.
  el.setAttribute('aria-live', 'polite');
  el.style.cssText = [
    'position:fixed',
    // A la izquierda de la columna del navegador integrado cuando está abierto.
    'right:calc(var(--browser-w, 0px) + 16px)',
    'bottom:76px', // por encima de la barra de estado y de los puntos de alerta (alerts.ts)
    'z-index:9000',
    'display:flex',
    'flex-direction:column',
    'gap:8px',
    'align-items:flex-end',
    'pointer-events:none',
  ].join(';');
  document.body.appendChild(el);
  return el;
}

function accentFor(kind: NoticeKind): string {
  if (kind === 'ok') return 'var(--success, var(--accent))';
  if (kind === 'error') return 'var(--danger)';
  return 'var(--accent)';
}

/**
 * Muestra un aviso. Devuelve una función para retirarlo antes de tiempo.
 *
 * `durationMs = 0` lo deja fijo hasta que se llame a esa función: es lo que
 * hace falta cuando el aviso acompaña a una operación en curso.
 */
export function notice(message: string, kind: NoticeKind = 'info', durationMs = 4000): () => void {
  const host = container();

  const card = document.createElement('div');
  card.style.cssText = [
    'pointer-events:auto',
    'max-width:420px',
    'padding:10px 14px',
    'border-radius:8px',
    'border:1px solid var(--border)',
    'border-left:3px solid ' + accentFor(kind),
    'background:var(--bg-elevated, var(--bg-panel))',
    'color:var(--text)',
    'font-size:12px',
    'line-height:1.45',
    'box-shadow:0 6px 20px rgba(0,0,0,.35)',
    'opacity:0',
    'transform:translateY(6px)',
    'transition:opacity .15s ease, transform .15s ease',
    'white-space:pre-wrap',
    'word-break:break-word',
  ].join(';');
  // textContent, nunca innerHTML: el mensaje puede llevar una ruta del sistema
  // de archivos o el texto de un error del motor, y ninguno de los dos está
  // saneado.
  card.textContent = message;

  host.appendChild(card);
  while (host.childElementCount > MAX_VISIBLE) {
    host.firstElementChild?.remove();
  }

  // Un fotograma antes de animar, para que la transición tenga desde dónde
  // salir; sin esto el elemento nace ya en su estado final y no hay animación.
  requestAnimationFrame(() => {
    card.style.opacity = '1';
    card.style.transform = 'translateY(0)';
  });

  let closed = false;
  const close = () => {
    if (closed) return;
    closed = true;
    card.style.opacity = '0';
    card.style.transform = 'translateY(6px)';
    window.setTimeout(() => card.remove(), 180);
  };

  if (durationMs > 0) window.setTimeout(close, durationMs);
  return close;
}
