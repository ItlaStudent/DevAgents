/** Texto no confiable en HTML o atributos entre comillas; nunca en JS, CSS o URLs. */
export function escapeText(value: unknown): string {
  const entities: Record<string, string> = {
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;', '`': '&#96;',
  };
  return String(value ?? '').replace(/[&<>"'`]/g, character => entities[character]);
}

/** Los atributos deben ir entre comillas. Este escape no autoriza esquemas de URL. */
export const escapeAttribute = escapeText;


/**
 * — plantillas HTML con escape POR DEFECTO.
 *
 * `html\`<b>${dato}</b>\`` escapa cada interpolación con `escapeText`; olvidar
 * el escape deja de ser posible. Solo se inserta tal cual lo que ya es
 * `SafeHtml` (otra plantilla `html`, o marcado fijo marcado con `raw()`), y
 * las listas de `SafeHtml` se concatenan. `setHtml` es el único punto que
 * asigna `innerHTML` desde estas plantillas.
 */
export class SafeHtml {
  constructor(readonly value: string) {}
  toString(): string {
    return this.value;
  }
}

/** Marca como seguro marcado FIJO del propio código (iconos SVG, constantes). Nunca datos. */
export function raw(markup: string): SafeHtml {
  return new SafeHtml(markup);
}

function interpolate(value: unknown): string {
  if (value instanceof SafeHtml) return value.value;
  if (Array.isArray(value)) return value.map(interpolate).join('');
  return escapeText(value);
}

/** Etiqueta de plantilla: escapa toda interpolación que no sea `SafeHtml`. */
export function html(strings: TemplateStringsArray, ...values: unknown[]): SafeHtml {
  let out = strings[0];
  for (let i = 0; i < values.length; i += 1) out += interpolate(values[i]) + strings[i + 1];
  return new SafeHtml(out);
}

/** Une varios `SafeHtml` (o una lista) en uno solo. */
export function joinHtml(items: unknown[]): SafeHtml {
  return new SafeHtml(items.map(interpolate).join(''));
}

/**
 * Borde seguro para datos que cruzan una frontera no tipada (eventos, mensajes):
 * si el valor ya es `SafeHtml` se conserva —solo los helpers de este módulo lo
 * fabrican y todo lo que interpolan queda escapado—; cualquier otra cosa (en
 * particular un `string` llegado de fuera) se escapa como texto. El sumidero no
 * necesita confiar en el productor.
 */
export function asSafeHtml(value: unknown): SafeHtml {
  return value instanceof SafeHtml ? value : new SafeHtml(escapeText(value));
}

/** Asigna `SafeHtml` a un elemento. */
export function setHtml(element: Element, content: SafeHtml): void {
  element.innerHTML = content.value;
}
