/**
 * S8 — en qué montón va una sesión según cuándo se creó.
 *
 * Vive aparte del enrutador de vistas por una razón concreta: es la única parte
 * de la lista de sesiones que se puede equivocar en silencio. El motor guarda
 * `created_at` en SEGUNDOS y `Date` trabaja en milisegundos; sin la conversión
 * todo cae en 1970, el agrupado mete las 215 sesiones en «Anteriores» y la
 * pantalla no se ve rota — solo inútil. Aquí se puede probar sin DOM.
 *
 * Los cortes son los que usa cualquiera al recordar: hoy, ayer, esta semana, y
 * todo lo anterior junto. Separar además por meses cambiaría una pared por otra.
 */

export function grupoPorFecha(createdAtSegundos: number, ahora: Date = new Date()): string {
  if (!createdAtSegundos || createdAtSegundos <= 0) return 'Sin fecha';
  const inicioHoy = new Date(ahora.getFullYear(), ahora.getMonth(), ahora.getDate()).getTime();
  const t = createdAtSegundos * 1000;
  const DIA = 86400000;
  // Una fecha futura (reloj desajustado, importación) cuenta como hoy: nunca
  // debe caer en «Anteriores», que es donde nadie la buscaría.
  if (t >= inicioHoy) return 'Hoy';
  if (t >= inicioHoy - DIA) return 'Ayer';
  if (t >= inicioHoy - 7 * DIA) return 'Esta semana';
  return 'Anteriores';
}

/**
 * 22-09 — ¿Sigue esperando decisión un plan propuesto?
 *
 * «Esperan tu aprobación» llegó a listar 89 filas: planes de hace días que
 * nadie iba a retomar, y muchas charlas de antes del arreglo C-11 que se
 * quedaron en 'planned' aunque ya estaban respondidas. Una bandeja que nunca
 * se vacía deja de leerse. Solo cuenta como pendiente un plan de las últimas
 * 24 horas; los anteriores siguen en su día, reabribles, con una marca neutra.
 * No se toca la base: el estado 'planned' sigue siendo el que es.
 */
export const VIGENCIA_PLAN_SEG = 24 * 3600;

export function planPendienteVigente(
  estado: string,
  createdAtSegundos: number,
  ahora: Date = new Date()
): boolean {
  if (estado !== 'planned') return false;
  if (!createdAtSegundos || createdAtSegundos <= 0) return false;
  return Math.floor(ahora.getTime() / 1000) - createdAtSegundos < VIGENCIA_PLAN_SEG;
}

/**
 * 22-09: la más reciente primero. El motor lista primero las órdenes que tiene
 * en memoria y las recién creadas se añaden AL FINAL; la barra no ordenaba, así
 * que una orden de hace un minuto salía la última de «Hoy», y el agrupado por
 * conversación (que toma la primera como la más reciente) elegía mal la fila.
 * A igual fecha desempata el id (la orden más nueva tiene id mayor).
 */
export function ordenarPorReciente<
  T extends { created_at?: number; order_id?: number; id?: number }
>(sesiones: T[]): T[] {
  return [...sesiones].sort(
    (a, b) =>
      Number(b.created_at ?? 0) - Number(a.created_at ?? 0) ||
      Number(b.order_id ?? b.id ?? 0) - Number(a.order_id ?? a.id ?? 0)
  );
}

/**
 * — ¿toca esta sesión en la barra con el interruptor actual?
 *
 * El motor devuelve `archived_at` (epoch SEGUNDOS; `0`/`null` = activa) y ya
 * filtra por su cuenta, pero la barra lo comprueba también aquí: la lista en
 * caché puede ser la del modo anterior mientras el interruptor acaba de
 * cambiar. Una archivada colada en el día a día se lee como un fallo del
 * archivado, y al invertir la regla la activa desaparece del historial —
 * ninguna de las dos rompe la pantalla, solo pierde sesiones.
 */
export function visibleEnBarra(
  sesion: { archived_at?: number | null } | null | undefined,
  verArchivadas: boolean
): boolean {
  const archivada = Number(sesion?.archived_at ?? 0) > 0;
  return verArchivadas ? archivada : !archivada;
}

/**
 * — estados TERMINALES: los únicos que se pueden archivar.
 *
 * Una orden en curso (`running`, `planning`, `awaiting_approval`…) no puede
 * desaparecer del historial mientras trabaja. La misma lista vive en
 * `session_store.archiveSession`; si una cambia, la otra debe cambiar con
 * ella o el botón ofrecerá archivar algo que el motor rechazará en silencio.
 */
const ESTADOS_ARCHIVABLES = new Set([
  'done',
  'failed',
  'rejected',
  'cancelled',
  'audit_unavailable',
]);

export function esArchivable(estado: string | number | undefined | null): boolean {
  return ESTADOS_ARCHIVABLES.has(String(estado ?? ''));
}

/** ¿Coincide esta sesión con lo que se ha escrito en el buscador? */
export function coincideBusqueda(titulo: string, orderId: number, filtro: string): boolean {
  const f = filtro.trim().toLowerCase();
  if (!f) return true;
  // También por número de orden: es como el usuario las nombra cuando viene de
  // la traza («la 214»).
  return titulo.toLowerCase().includes(f) || String(orderId).includes(f);
}

/** Una fila de la barra lateral: la orden que la representa y cuántas agrupa. */
export interface FilaDeSesion<T> {
  cabeza: T;
  cuantas: number;
}

/** Conserva el hilo real al reabrir una sesión; solo las sesiones legacy usan el fallback. */
export function conversationIdForSession(session: {
  id?: number;
  order_id?: number;
  conversation_id?: string | null;
}): string {
  const persisted = String(session.conversation_id ?? '').trim();
  if (persisted) return persisted;
  const orderId = Number(session.order_id ?? session.id ?? 0);
  return `orden-${orderId}`;
}

/**
 * Colapsa en UNA fila las órdenes que pertenecen al mismo hilo.
 *
 * Cada petición dentro de una conversación abre su propia orden, así que pedir
 * cinco cosas seguidas dejaba cinco filas casi idénticas en la barra lateral
 * aunque el contexto fuese continuo: el agente se acordaba de todo y el panel
 * lo enseñaba troceado. El vínculo orden→hilo ya se guardaba en la tabla
 * `orders` (`conversation_id`); lo único que faltaba era usarlo aquí.
 *
 * La representante es la PRIMERA que llega, y la lista viene ordenada por fecha
 * descendente, así que es la más reciente: la que trae el hilo entero.
 *
 * Las órdenes sin `conversation_id` —las lanzadas por CLI, y todas las
 * anteriores a que esto existiera— quedan como filas sueltas. Agruparlas por su
 * cadena vacía las juntaría TODAS en una sola entrada, que es peor que el
 * problema que se está resolviendo.
 */
export function agruparPorConversacion<
  T extends { conversation_id?: string | null }
>(sesiones: T[]): Array<FilaDeSesion<T>> {
  const filas: Array<FilaDeSesion<T>> = [];
  const porHilo = new Map<string, FilaDeSesion<T>>();
  for (const s of sesiones) {
    const hilo = String(s.conversation_id ?? '').trim();
    if (!hilo) {
      filas.push({ cabeza: s, cuantas: 1 });
      continue;
    }
    const ya = porHilo.get(hilo);
    if (ya) {
      ya.cuantas += 1;
    } else {
      const fila = { cabeza: s, cuantas: 1 };
      porHilo.set(hilo, fila);
      filas.push(fila);
    }
  }
  return filas;
}
