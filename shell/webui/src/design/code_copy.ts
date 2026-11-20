/**
 * — botón «Copiar» de los bloques de código del chat.
 *
 * `markdown.ts` emite el botón (marcado fijo, sin datos del modelo) y este
 * módulo lo cablea con UN delegado en el contenedor, igual que «Ejecutar
 * esto»: sigue vivo tras cada repintado del hilo y no hay un listener por
 * bloque. Lo que se copia es el `textContent` del <code> del mismo <pre>: el
 * texto exacto del bloque, sin número de línea ni lenguaje, y nunca un
 * atributo que el modelo pudiera haber manipulado.
 */
import { notice } from './notice';

export const COPY_LABEL = 'Copiar';
export const COPY_DONE_LABEL = 'Copiado';
const COPY_ARIA = 'Copiar código';
const COPY_DONE_ARIA = 'Código copiado';
const CONFIRM_MS = 1500;

/** Ruta alternativa para contextos donde `navigator.clipboard` no está disponible. */
function copyWithSelection(text: string): boolean {
  const area = document.createElement('textarea');
  area.value = text;
  area.setAttribute('readonly', '');
  area.setAttribute('aria-hidden', 'true');
  area.style.cssText = 'position:fixed;top:0;left:0;opacity:0;pointer-events:none';
  document.body.appendChild(area);
  const previous = document.activeElement as HTMLElement | null;
  area.select();
  let ok = false;
  try {
    ok = document.execCommand('copy');
  } catch {
    ok = false;
  }
  area.remove();
  previous?.focus?.();
  return ok;
}

/** Copia `text`; devuelve false si ninguna vía lo consiguió. */
export async function writeClipboardText(text: string): Promise<boolean> {
  try {
    const clip = typeof navigator !== 'undefined' ? navigator.clipboard : undefined;
    if (clip?.writeText) {
      await clip.writeText(text);
      return true;
    }
  } catch {
    /* sin permiso o sin foco: se prueba la vía alternativa */
  }
  return copyWithSelection(text);
}

/** Confirmación breve en el propio botón; el aria-label cambia con el texto. */
function confirmCopied(btn: HTMLElement): void {
  const w = window as unknown as { setTimeout: (fn: () => void, ms: number) => number; clearTimeout: (id: number) => void };
  const previous = Number(btn.dataset.copyTimer || 0);
  if (previous) w.clearTimeout(previous);
  btn.textContent = COPY_DONE_LABEL;
  btn.setAttribute('aria-label', COPY_DONE_ARIA);
  btn.dataset.copied = 'true';
  btn.dataset.copyTimer = String(
    w.setTimeout(() => {
      btn.textContent = COPY_LABEL;
      btn.setAttribute('aria-label', COPY_ARIA);
      delete btn.dataset.copied;
      delete btn.dataset.copyTimer;
    }, CONFIRM_MS)
  );
}

/** Cablea el delegado de «Copiar» sobre `root` (una sola vez por contenedor). */
export function installCodeCopy(root: HTMLElement): void {
  root.addEventListener('click', (ev) => {
    const btn = (ev.target as HTMLElement).closest?.('.md-copy') as HTMLElement | null;
    if (!btn) return;
    const text = btn.closest('pre')?.querySelector('code')?.textContent ?? '';
    if (text === '') return;
    void writeClipboardText(text).then((ok) => {
      if (ok) confirmCopied(btn);
      else notice('No se pudo copiar el bloque al portapapeles.', 'error');
    });
  });
}
