import { escapeAttribute as escAttr } from '../design/html';
import { UMBRAL_PCT, porcentajeContexto, tokensEstimados } from './auto_compact';

/**
 * Fuente del uso de contexto que comparten el compositor del chat y la
 * tarjeta «Contexto» del panel derecho.
 *
 * La estimación sigue siendo la de `auto_compact.ts` (~4 caracteres por token
 * contra la ventana de 32768): aquí NO se recalcula nada, solo se compone el
 * resultado con los adjuntos pendientes y se decide el nivel (color) y el
 * aviso. Quien publica (`MissionControlPanel.publishThreadUsage`) construye
 * UN `UsoContexto`, lo manda por `devagents:thread-usage` a la tarjeta y
 * pinta con él el indicador del compositor: no hay un segundo cálculo que
 * pueda divergir.
 *
 * Mientras el motor no entregue recuento real de tokens, el valor es siempre
 * «Estimado».
 */

/** Evento con el que se publica el uso del hilo. */
export const EVENTO_USO_CONTEXTO = 'devagents:thread-usage';

/** Verde hasta 70 % incluido; amarillo por encima de 70 %. */
export const UMBRAL_AMARILLO_PCT = 70;
/** Rojo por encima de 90 %. */
export const UMBRAL_ROJO_PCT = 90;

export type NivelContexto = 'ok' | 'aviso' | 'critico';

/** Colores de la referencia visual (ESPECIFICACION-REFERENCIAS.txt §4). */
export const COLOR_NIVEL: Record<NivelContexto, string> = {
  ok: '#79996A',
  aviso: '#C89246',
  critico: '#C4553D',
};

export function nivelContexto(pct: number): NivelContexto {
  if (pct > UMBRAL_ROJO_PCT) return 'critico';
  if (pct > UMBRAL_AMARILLO_PCT) return 'aviso';
  return 'ok';
}

export function colorContexto(pct: number): string {
  return COLOR_NIVEL[nivelContexto(pct)];
}

/** Tope aproximado de tokens que cuesta una imagen adjunta. */
export const TOKENS_IMAGEN_MAX = 1600;
/** Texto con el que el compositor cita un archivo adjunto antes de su contenido. */
const CABECERA_ADJUNTO_CHARS = 32;

/** ~píxeles/750 tokens, acotado: estimación, igual que el resto. */
export function tokensImagen(ancho: number, alto: number): number {
  const px = Math.max(0, Number(ancho) || 0) * Math.max(0, Number(alto) || 0);
  return Math.min(TOKENS_IMAGEN_MAX, Math.max(1, Math.ceil(px / 750)));
}

/** Lo mínimo que se necesita de un adjunto del compositor (texto o imagen). */
export type AdjuntoContexto =
  | { name: string; content: string }
  | { name: string; width: number; height: number; elementContext?: string };

/**
 * Caracteres equivalentes de los adjuntos pendientes. El texto cuenta lo que
 * se cita en el prompt; la imagen, sus tokens estimados expresados en
 * caracteres (×4) más el contexto del elemento señalado, que sí se cita.
 */
export function caracteresAdjuntos(adjuntos: readonly AdjuntoContexto[]): number {
  let total = 0;
  for (const a of adjuntos) {
    if ('content' in a) {
      total += CABECERA_ADJUNTO_CHARS + String(a.name || '').length + String(a.content || '').length;
    } else {
      total += tokensImagen(a.width, a.height) * 4 + (a.elementContext ? a.elementContext.length : 0);
    }
  }
  return total;
}

export interface UsoContexto {
  /** Caracteres del hilo más los adjuntos pendientes. */
  chars: number;
  tokens: number;
  /** null cuando no hay hilo ni adjuntos: no se inventa un 0 %. */
  pct: number | null;
  turns: number;
  /** De `chars`, los que son adjuntos pendientes del compositor. */
  adjuntosChars: number;
}

export function usoContexto(hiloChars: number, turns: number, adjuntosChars = 0): UsoContexto {
  const chars = Math.max(0, hiloChars) + Math.max(0, adjuntosChars);
  const hayDatos = turns > 0 || adjuntosChars > 0;
  return {
    chars,
    tokens: tokensEstimados(chars),
    pct: hayDatos ? porcentajeContexto(chars) : null,
    turns,
    adjuntosChars: Math.max(0, adjuntosChars),
  };
}

/** ¿Se ha pasado el umbral desde el que la cabina avisa y compacta? */
export function avisaCompactacion(pct: number | null): boolean {
  return pct !== null && pct >= UMBRAL_PCT;
}

export interface OpcionesIndicador {
  /** Hay al menos dos turnos y nada en vuelo: «Compactar ahora» tiene sentido. */
  puedeCompactar: boolean;
  /** Hay una compactación en marcha. */
  compactando: boolean;
}

export const ID_INDICADOR_CONTEXTO = 'composer-context';
export const ID_COMPACTAR_COMPOSITOR = 'composer-context-compact';

/** Etiqueta accesible: el mismo número que la tarjeta, con su calificativo. */
export function etiquetaContexto(pct: number): string {
  return `Contexto usado: ${pct} % (estimado)`;
}

/**
 * Contenido del indicador del compositor ('' si no hay datos: el host se
 * oculta). El porcentaje se escribe con el mismo formato que la tarjeta
 * («75 %») para que la prueba de coherencia compare texto con texto.
 */
export function indicadorContextoHtml(uso: UsoContexto, op: OpcionesIndicador): string {
  if (uso.pct === null) return '';
  const pct = uso.pct;
  const nivel = nivelContexto(pct);
  const detalle = `${uso.tokens} tokens estimados · ${uso.chars} caracteres`;
  const aviso = avisaCompactacion(pct);
  let accion = '';
  if (aviso) {
    accion = op.compactando
      ? `<span class="ctx-meter__warn" role="status">Compactando el hilo…</span>`
      : `<span class="ctx-meter__warn" role="status">Contexto casi lleno: se compactará sola al ${UMBRAL_PCT} %</span>` +
        (op.puedeCompactar
          ? `<button class="btn btn--sm ctx-meter__compact" type="button" id="${ID_COMPACTAR_COMPOSITOR}" title="Resume el historial de la conversación para liberar contexto del modelo">Compactar ahora</button>`
          : '');
  }
  return (
    `<span class="ctx-meter__gauge" role="meter" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${pct}" ` +
    `aria-label="${escAttr(etiquetaContexto(pct))}" title="${escAttr(detalle)}">` +
    `<span class="ctx-meter__track" aria-hidden="true"><span class="ctx-meter__fill" style="width:${pct}%;background:${COLOR_NIVEL[nivel]}"></span></span>` +
    `<span class="ctx-meter__pct" data-ctx-pct>${pct} %</span>` +
    `<span class="ctx-meter__label">Estimado</span>` +
    `</span>` +
    accion
  );
}

/** Texto del indicador (útil para pruebas y para el lector de pantalla). */
export function textoIndicador(uso: UsoContexto): string {
  return uso.pct === null ? '' : `${uso.pct} %`;
}
