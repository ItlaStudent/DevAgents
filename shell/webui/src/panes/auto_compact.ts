/**
 * D6 — compactación automática por umbral de tokens.
 *
 * Antes de esto había una tarjeta al 75 % con «Compactar ahora» y «Posponer».
 * Sin clic no pasaba nada, así que la compactación "automática" era manual con
 * otro nombre: el hilo seguía creciendo hasta que el modelo truncaba la
 * respuesta. Lo que faltaba no era la tarjeta, era el disparo.
 *
 * La lógica vive aquí, fuera del panel, por dos razones: para poder probarla
 * sin DOM (`tests/auto_compact_test.cjs`) y porque el panel ya tiene 1.500
 * líneas. Aquí NO se toca la interfaz ni se llama al motor: se decide.
 */

/** Ventana de contexto asumida. Es la del modelo más pequeño del catálogo. */
export const LIMITE_CONTEXTO_TOKENS = 32768;

/** A partir de aquí se avisa y arranca la cuenta atrás. */
export const UMBRAL_PCT = 75;

/**
 * Segundos de cuenta atrás antes de compactar sola.
 *
 * No es un adorno: compactar DESTRUYE el detalle del hilo a propósito. Hacerlo
 * sin margen para cancelar convierte una ayuda en una pérdida de datos. Diez
 * segundos es lo que tarda alguien en leer el aviso y decidir.
 */
export const CUENTA_ATRAS_S = 10;

/** Estimación por caracteres: ~4 caracteres por token en español e inglés. */
export function tokensEstimados(caracteres: number): number {
  return Math.round(caracteres / 4);
}

/** Porcentaje de la ventana ocupado, acotado a 100. */
export function porcentajeContexto(caracteres: number, limite: number = LIMITE_CONTEXTO_TOKENS): number {
  if (limite <= 0) return 0;
  return Math.min(100, Math.round((tokensEstimados(caracteres) / limite) * 100));
}

/**
 * Estado por HILO. Se reinicia al abrir conversación nueva; `pospuesto` no se
 * hereda, porque posponer en un hilo no dice nada del siguiente.
 */
export interface EstadoAutoCompactacion {
  /** El usuario pulsó «Posponer» en ESTE hilo. */
  pospuesto: boolean;
  /** Hay una compactación en vuelo (no se lanza otra encima). */
  enMarcha: boolean;
  /** Segundos que quedan, o null si no hay cuenta atrás corriendo. */
  restanS: number | null;
  /**
   * El último intento falló (proveedor caído, sin clave…). No se reintenta
   * solo: reintentar en bucle contra un proveedor caído quema cuota y deja el
   * aviso parpadeando. Se rearma cuando el usuario pulsa «Compactar ahora».
   */
  falloPrevio: boolean;
}

export function estadoInicial(): EstadoAutoCompactacion {
  return { pospuesto: false, enMarcha: false, restanS: null, falloPrevio: false };
}

export type Decision =
  /** Ni tarjeta ni disparo. */
  | { accion: 'nada' }
  /** Mostrar la tarjeta y arrancar la cuenta atrás desde `restanS`. */
  | { accion: 'arrancar'; pct: number; restanS: number }
  /** La cuenta atrás sigue viva; solo hay que pintar. */
  | { accion: 'contando'; pct: number; restanS: number }
  /** Se acabó el plazo: compactar ahora. */
  | { accion: 'compactar'; pct: number };

/**
 * Decide qué hacer con el hilo actual. Función pura: mismas entradas, misma
 * salida, sin tocar `estado`.
 *
 * `turnos` < 2 no dispara nada — no hay conversación que resumir, y un resumen
 * de un solo turno pierde información sin ganar nada.
 */
export function decidir(
  caracteresDelHilo: number,
  turnos: number,
  estado: EstadoAutoCompactacion,
  limite: number = LIMITE_CONTEXTO_TOKENS,
): Decision {
  const pct = porcentajeContexto(caracteresDelHilo, limite);
  if (pct < UMBRAL_PCT) return { accion: 'nada' };
  if (turnos < 2) return { accion: 'nada' };
  if (estado.pospuesto || estado.enMarcha || estado.falloPrevio) return { accion: 'nada' };

  if (estado.restanS === null) return { accion: 'arrancar', pct, restanS: CUENTA_ATRAS_S };
  if (estado.restanS > 0) return { accion: 'contando', pct, restanS: estado.restanS };
  return { accion: 'compactar', pct };
}

/**
 * Aplica un tic de un segundo. Devuelve el estado nuevo (no muta el que entra).
 * Sin cuenta atrás en marcha es la identidad.
 */
export function tic(estado: EstadoAutoCompactacion): EstadoAutoCompactacion {
  if (estado.restanS === null) return estado;
  return { ...estado, restanS: Math.max(0, estado.restanS - 1) };
}

/** «Posponer»: se apaga para este hilo hasta que el usuario pida compactar. */
export function posponer(estado: EstadoAutoCompactacion): EstadoAutoCompactacion {
  return { ...estado, pospuesto: true, restanS: null };
}

/** Arranca la cuenta atrás (lo que devuelve `decidir` con acción `arrancar`). */
export function arrancar(estado: EstadoAutoCompactacion, restanS: number = CUENTA_ATRAS_S): EstadoAutoCompactacion {
  return { ...estado, restanS };
}

/** Marca que la compactación está en vuelo. */
export function enMarcha(estado: EstadoAutoCompactacion): EstadoAutoCompactacion {
  return { ...estado, enMarcha: true, restanS: null };
}

/**
 * Cierre de una compactación. `ok=false` deja `falloPrevio` puesto para que el
 * disparo automático no vuelva a intentarlo solo.
 */
export function terminada(estado: EstadoAutoCompactacion, ok: boolean): EstadoAutoCompactacion {
  if (ok) return estadoInicial();
  return { ...estado, enMarcha: false, restanS: null, falloPrevio: true };
}

/** «Compactar ahora» manual: rearma el fallo previo y el posponer. */
export function forzada(estado: EstadoAutoCompactacion): EstadoAutoCompactacion {
  return { ...estado, pospuesto: false, falloPrevio: false, enMarcha: true, restanS: null };
}
