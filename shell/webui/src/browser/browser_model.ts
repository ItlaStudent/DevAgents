/**
 * Modelo puro del navegador integrado: tipos del estado que publica el host,
 * normalización de la dirección escrita y textos. Sin DOM, para poder probarlo
 * en Node. La WebUI NUNCA decide por sí misma qué sitio se abre: normaliza lo
 * que el usuario escribió y lo manda al host, que aplica la política.
 */

export type BrowserTrust = 'fixture' | 'app' | 'approved' | 'none';
export type ApprovalSource = 'address' | 'agent' | 'link' | 'page' | 'redirect' | 'popup';

export interface BrowserTab {
  id: number;
  title: string;
  url: string;
  origin: string;
  trust: BrowserTrust;
  loading: boolean;
  ready: boolean;
  can_back: boolean;
  can_forward: boolean;
  error: { code: number; detail: string; reason: string } | null;
  blocked: { origin: string; url: string; reason: string } | null;
}

export interface BrowserApproval {
  id: string;
  origin: string;
  source: ApprovalSource;
}

export interface BrowserState {
  open: boolean;
  full: boolean;
  ready: boolean;
  bar_css: number;
  panel_px: number;
  active: number;
  status: string;
  status_error: boolean;
  tabs: BrowserTab[];
  approvals: BrowserApproval[];
  session_id?: string;
  control_state?: BrowserControl;
  control_epoch?: number;
  /** La página nativa está oculta tras una imagen fija porque una capa de la cabina la pisa. */
  covered?: boolean;
}

export type BrowserControl = 'agent_control' | 'user_control' | 'session_closed';

export function controlLabel(state?: BrowserControl): string {
  return state === 'agent_control' ? 'Tomar control' : state === 'user_control' ? 'Reanudar agente' : 'Sin sesión de agente';
}

export interface BrowserEvent {
  request_id: string;
  tool: string;
  state: string;
  elapsed_ms?: number;
  code?: string;
}

/** Solo metadatos correlacionados. Nunca se representa el objeto completo. */
export function browserEventText(event: BrowserEvent): string {
  const text = (value: string) => value.replace(/[\u0000-\u001f\u007f-\u009f\u202a-\u202e\u2066-\u2069]/g, '').slice(0, 160);
  return [text(event.tool), text(event.state), ...(Number.isFinite(event.elapsed_ms) ? [Math.max(0, event.elapsed_ms ?? 0) + ' ms'] : []), ...(event.code ? [text(event.code)] : []), text(event.request_id)].join(' · ');
}

/** Tipos de tarjeta que ocupan el lugar de la página cuando esta no se ve. */
export type BodyKind = 'page' | 'starting' | 'empty' | 'error' | 'blocked' | 'waiting';

export function activeTab(state: BrowserState): BrowserTab | null {
  return state.tabs.find((tab) => tab.id === state.active) ?? null;
}

/** Misma regla que el host (`ShowsPage`): decide qué pinta la WebUI debajo de la barra. */
export function bodyKind(state: BrowserState): BodyKind {
  const tab = activeTab(state);
  if (!state.ready && (!tab || !tab.url)) return 'starting';
  if (!tab) return 'empty';
  if (state.approvals.length) return 'waiting';
  if (tab.blocked) return 'blocked';
  if (tab.error) return 'error';
  if (!tab.url) return state.ready ? 'empty' : 'starting';
  return tab.ready ? 'page' : 'starting';
}

const SCHEME = /^[a-z][a-z0-9+.-]*:\/\//i;
const LOCAL_HOST = /^(?:localhost|127\.0\.0\.1|\[::1\])(?::\d{1,5})?(?:[/?#].*)?$/i;

export type Normalized = { url: string; error?: undefined } | { url?: undefined; error: string };

/**
 * Convierte lo escrito en la barra en una URL http(s). Sin buscador: una frase
 * suelta no es una dirección y se dice así, en vez de mandarla a un tercero.
 */
export function normalizeAddress(raw: string): Normalized {
  const text = raw.trim();
  if (!text) return { error: 'Escribe una dirección.' };
  if (text.length > 8192) return { error: 'La dirección es demasiado larga.' };
  // Un archivo del proyecto (file:///…, C:\…, o una ruta relativa a un .html):
  // lo resuelve el host, que solo sirve los de la carpeta de la orden por su
  // origen local controlado. Las rutas de Windows pueden llevar espacios.
  if (/^file:\/\//i.test(text) || /^[a-z]:[\\/]/i.test(text)) return { url: text };
  if (/\s/.test(text)) return { error: 'La dirección no puede llevar espacios.' };
  if (text === 'about:blank') return { url: text };
  if (!text.includes(':') && /^[^?#]+\.html?$/i.test(text)) return { url: text };
  if (SCHEME.test(text)) {
    return /^https?:\/\//i.test(text) ? { url: text } : { error: 'Solo se abren direcciones http o https.' };
  }
  if (LOCAL_HOST.test(text)) return { url: 'http://' + text };
  if (/^[^/?#]+\.[^/?#]+/.test(text)) return { url: 'https://' + text };
  return { error: 'Escribe una dirección completa, por ejemplo localhost:3000 o ejemplo.com.' };
}

/** Un puerto de localhost es lo único que «Registrar app» acepta. */
export function localAppUrl(raw: string): string | null {
  const parsed = normalizeAddress(raw);
  if (!parsed.url) return null;
  const match = /^http:\/\/(?:localhost|127\.0\.0\.1|\[::1\]):(\d{1,5})(?:[/?#]|$)/i.exec(parsed.url);
  if (!match) return null;
  const port = Number(match[1]);
  return port >= 1 && port <= 65535 ? parsed.url : null;
}

export function trustLabel(trust: BrowserTrust): string {
  switch (trust) {
    case 'fixture':
      return 'Página de la orden';
    case 'app':
      return 'App registrada';
    case 'approved':
      return 'Sitio aprobado';
    default:
      return 'Sin origen';
  }
}

export function sourceLabel(source: ApprovalSource): string {
  switch (source) {
    case 'address':
      return 'Tú, desde la barra de direcciones.';
    case 'agent':
      return 'El agente de esta orden, para abrir la página que le pediste o que está comprobando.';
    case 'link':
      return 'Un enlace de la página en el que hiciste clic.';
    case 'redirect':
      return 'Una redirección del servidor de la página.';
    case 'popup':
      return 'Una ventana nueva que la página abrió tras un clic tuyo.';
    default:
      return 'Un script de la página, sin que hicieras nada.';
  }
}

/** Nombre corto de una pestaña: título, o el host, o «Nueva pestaña». */
export function tabLabel(tab: BrowserTab): string {
  if (!tab.url) return 'Nueva pestaña';
  const title = tab.title.trim();
  if (title && title !== 'about:blank') return title;
  return tab.origin.replace(/^https?:\/\//i, '').replace(/:(80|443)$/, '') || tab.url;
}

/** Inicial para el marcador de la pestaña (no hay favicon: se pintaría con datos de la página). */
export function tabInitial(tab: BrowserTab): string {
  if (!tab.url) return '+';
  // Un título dice más que una IP o «localhost»; sin título, el host.
  const source = tab.title.trim() && tab.title !== 'about:blank' ? tab.title : tab.origin.replace(/^https?:\/\//i, '');
  const letter = Array.from(source.replace(/^[^a-z0-9]+/i, ''))[0];
  return (letter ?? '?').toUpperCase();
}

/**
 * Los puntos de ruptura de la hoja de estilos miden el ancho que le queda a la
 * cabina, no el de la ventana: con el navegador abierto, el viewport sigue
 * entero y la columna del navegador lo cubre.
 */
export const BREAKPOINTS = [1400, 1100, 1024, 860, 760, 620] as const;
export function breakpointFlags(innerWidth: number, browserCssWidth: number): string {
  const effective = innerWidth - Math.max(0, browserCssWidth);
  return BREAKPOINTS.filter((limit) => effective <= limit).join(' ');
}
