/**
 * Tanda 5 (F0.4,): actualizador «avisar y aplicar al cerrar» en la
 * cabina. Dos piezas:
 *
 * - `renderUpdateSettings`: la tarjeta de Ajustes › Acerca de, con el
 *   interruptor «Buscar actualizaciones una vez al día», «Buscar ahora», el
 *   último resultado con su fecha y, si hay algo, descargar / no instalar.
 * - `updateAlert`: el aviso de esquina (design/alerts) cuando hay versión
 *   nueva o cuando ya está lista para instalarse al cerrar.
 *
 * Todo lo que viene de GitHub (versión, fecha, enlace) se pinta con
 * textContent, nunca como HTML. El enlace a las notas lo abre el host fuera
 * (`shell.open`), como los demás enlaces externos; el motor solo lo guarda si
 * apunta a las publicaciones del repositorio.
 */
import type { AlertSpec } from '../design/alerts';

export type UpdateStatus = 'nunca' | 'al_dia' | 'disponible' | 'sin_publicaciones' | 'error' | 'desactivado';

export interface UpdateRelease {
  version: string;
  tag: string;
  notes_url: string | null;
  published_at: string;
}

export interface UpdateStaged {
  version: string;
  path: string;
  sha256: string;
  signature: 'valida' | 'sin_firma';
  signature_code?: number;
  /** T12 M3: firma válida del editor fijado de DevAgents. Si no, instalarla
   *  exige el consentimiento «sin firma verificable». */
  verified?: boolean;
}

export interface UpdateState {
  enabled: boolean;
  current: string;
  checked_ms: number | null;
  status: UpdateStatus;
  detail: string;
  latest: UpdateRelease | null;
  staged: UpdateStaged | null;
  apply_on_exit: boolean;
  /** T12 M3: el usuario aceptó instalarla sin firma verificable. */
  apply_unverified?: boolean;
  download_error: string | null;
}

export interface UpdateActions {
  setEnabled(enabled: boolean): void;
  checkNow(): void;
  download(): void;
  /** `unverified` = consentimiento explícito de instalar sin firma verificable. */
  applyOnExit(apply: boolean, unverified?: boolean): void;
  openNotes(url: string): void;
}

export function isUpdateState(value: unknown): value is UpdateState {
  if (!value || typeof value !== 'object') return false;
  const s = value as Partial<UpdateState>;
  return typeof s.enabled === 'boolean' && typeof s.status === 'string' && typeof s.current === 'string';
}

export const SIGNATURE_TEXT: Record<UpdateStaged['signature'], string> = {
  valida: 'Firmada y válida.',
  sin_firma: 'Sin firma reconocida (la huella SHA-256 sí coincide).',
};

/** T12 M3: lo que se le dice al usuario antes de aceptar una sin firma verificable. */
export const UNVERIFIED_TEXT =
  'Sin firma verificable del editor de DevAgents: la huella SHA-256 solo comprueba que la descarga llegó entera; sale de la misma publicación y no prueba quién la publicó.';

/** La versión preparada es la que anuncia el aviso: ya no hay que descargarla. */
export function stagedIsLatest(state: UpdateState): boolean {
  return !!state.staged && (!state.latest || state.staged.version === state.latest.version);
}

export function formatChecked(ms: number | null): string {
  if (!ms) return 'Nunca se ha buscado.';
  const d = new Date(ms);
  if (Number.isNaN(d.getTime())) return 'Fecha desconocida.';
  return `Última búsqueda: ${d.toLocaleString('es-ES', { dateStyle: 'medium', timeStyle: 'short' })}.`;
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls: string, text?: string): HTMLElementTagNameMap[K] {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text !== undefined) node.textContent = text;
  return node;
}

function button(id: string, label: string, run: () => void, primary = false): HTMLButtonElement {
  const b = el('button', primary ? 'btn btn--primary' : 'btn', label);
  b.type = 'button';
  b.id = id;
  b.addEventListener('click', run);
  return b;
}

function row(title: string, help: string, value: HTMLElement): HTMLElement {
  const r = el('div', 'settings-row');
  const k = el('div', 'settings-row__k');
  k.append(el('b', '', title), el('small', '', help));
  const v = el('div', 'settings-row__v');
  v.append(value);
  r.append(k, v);
  return r;
}

/** Tarjeta de Ajustes. `busy` deshabilita los botones mientras hay una llamada en curso. */
export function renderUpdateSettings(host: HTMLElement, state: UpdateState, actions: UpdateActions, busy = ''): void {
  host.replaceChildren();
  host.dataset.updateStatus = state.status;

  host.append(el('div', 'card__title', 'Actualizaciones'));
  host.append(el('div', 'card__subtitle', `Versión instalada: ${state.current}. Se instala al cerrar DevAgents, nunca con una orden en curso.`));

  const toggleLabel = el('label', 'row');
  toggleLabel.style.gap = '8px';
  const toggle = el('input', '');
  toggle.type = 'checkbox';
  toggle.id = 'update-enabled';
  toggle.checked = state.enabled;
  toggle.disabled = !!busy;
  toggle.addEventListener('change', () => actions.setEnabled(toggle.checked));
  toggleLabel.append(toggle, el('span', '', state.enabled ? 'Activado' : 'Desactivado'));
  host.append(row('Buscar actualizaciones una vez al día (no envía datos tuyos)', 'Una consulta a las publicaciones de DevAgents en GitHub, sin identificadores.', toggleLabel));

  const check = button('update-check-now', busy === 'check' ? 'Buscando…' : 'Buscar ahora', () => actions.checkNow());
  check.disabled = !!busy || !state.enabled;
  const result = el('div', 'col');
  const statusLine = el('span', 'update-status', state.detail);
  statusLine.id = 'update-status-text';
  if (state.status === 'error') statusLine.style.color = 'var(--danger)';
  if (state.status === 'disponible') statusLine.style.fontWeight = '600';
  const when = el('small', 'subtle', formatChecked(state.checked_ms));
  when.id = 'update-checked';
  result.append(statusLine, when);
  const resultRow = row('Último resultado', '', result);
  resultRow.querySelector('.settings-row__v')?.append(check);
  host.append(resultRow);

  if (state.latest && state.status === 'disponible' && state.latest.notes_url) {
    const notesUrl = state.latest.notes_url;
    const link = el('a', '', `Notas de la versión ${state.latest.version}`);
    link.id = 'update-notes';
    link.href = notesUrl;
    link.addEventListener('click', (e) => {
      e.preventDefault();
      actions.openNotes(notesUrl);
    });
    host.append(link);
  }

  if (state.download_error) {
    const err = el('div', 'update-download-error', `No se pudo preparar la actualización: ${state.download_error}`);
    err.id = 'update-download-error';
    err.setAttribute('role', 'alert');
    err.style.color = 'var(--danger)';
    host.append(err);
  }

  if (state.staged && stagedIsLatest(state)) {
    const box = el('div', 'col');
    box.id = 'update-staged';
    const line = state.apply_on_exit
      ? 'Lista. Se instalará al cerrar DevAgents, cuando no haya órdenes en curso.'
      : `DevAgents ${state.staged.version} está descargada, pero no se instalará.`;
    box.append(el('span', '', line), el('small', 'subtle', SIGNATURE_TEXT[state.staged.signature] ?? `Firma: ${state.staged.signature}`));
    const verified = state.staged.verified === true;
    if (!verified) {
      const warn = el('small', 'update-unverified', UNVERIFIED_TEXT);
      warn.id = 'update-unverified';
      warn.style.color = 'var(--danger)';
      box.append(warn);
    }
    // T12 M3: sin firma verificable no hay «Instalar» a secas: el botón dice
    // lo que se acepta y manda ese consentimiento al motor.
    const choice = state.apply_on_exit
      ? button('update-cancel', 'No instalar', () => actions.applyOnExit(false))
      : verified
        ? button('update-apply', 'Instalar al cerrar', () => actions.applyOnExit(true), true)
        : button('update-apply-unverified', 'Instalar al cerrar sin firma verificable', () => actions.applyOnExit(true, true));
    choice.disabled = !!busy;
    host.append(row(`DevAgents ${state.staged.version}`, '', box));
    box.parentElement?.append(choice);
  } else if (state.status === 'disponible' && state.latest) {
    const dl = button('update-download', busy === 'download' ? 'Descargando y verificando…' : 'Descargar', () => actions.download(), true);
    dl.disabled = !!busy;
    host.append(row(`DevAgents ${state.latest.version}`, 'Se baja y se comprueba su huella SHA-256 y su firma. Nada se instala hasta que cierres DevAgents.', dl));
  }
}

/** Lo que el controlador necesita del puente (CoreApi lo cumple). */
export interface UpdateCore {
  updateState(): Promise<unknown>;
  updateCheck(force: boolean): Promise<unknown>;
  updateDownload(): Promise<unknown>;
  updateSetEnabled(enabled: boolean): Promise<unknown>;
  updateApplyOnExit(apply: boolean, unverified?: boolean): Promise<unknown>;
  openPath(target: string): Promise<unknown>;
}

export interface UpdateAlerts {
  raise(spec: AlertSpec): void;
  clear(id: string): void;
}

/**
 * Estado compartido de la ventana: un solo controlador lo pide al motor, pinta
 * la tarjeta de Ajustes si está abierta y pone o quita el aviso de esquina.
 * Los fallos del puente se enseñan en la tarjeta, no se tragan.
 */
export class UpdateController {
  public state: UpdateState | null = null;
  public error = '';
  private busy = '';
  /** Versión que el usuario decidió no instalar (T12 M3: sin aviso repetido). */
  private declined = '';
  private host: HTMLElement | null = null;
  public readonly actions: UpdateActions;

  constructor(private core: UpdateCore, private alerts: UpdateAlerts) {
    this.actions = {
      setEnabled: (enabled) => void this.run('toggle', () => this.core.updateSetEnabled(enabled)),
      checkNow: () => void this.run('check', () => this.core.updateCheck(true)),
      download: () => void this.run('download', async () => {
        const after = await this.core.updateDownload();
        // El clic en «Descargar» es el consentimiento: si quedó preparada CON
        // firma verificable, se instala al cerrar (con «No instalar» para
        // echarse atrás). T12 M3: sin firma verificable se queda descargada y
        // la tarjeta pide el consentimiento expreso.
        if (isUpdateState(after) && after.staged && after.staged.verified === true && !after.download_error) return this.core.updateApplyOnExit(true);
        return after;
      }),
      applyOnExit: (apply, unverified) => {
        if (!apply && this.state?.staged) this.declined = this.state.staged.version;
        void this.run('apply', () => this.core.updateApplyOnExit(apply, unverified === true));
      },
      openNotes: (url) => {
        this.core.openPath(url).catch((e) => {
          this.error = `No se pudieron abrir las notas: ${String(e instanceof Error ? e.message : e)}`;
          this.render();
        });
      },
    };
  }

  /** Engancha la tarjeta de Ajustes (null la suelta). */
  attach(host: HTMLElement | null): void {
    this.host = host;
    this.render();
    if (host && !this.state) void this.refresh();
  }

  /** Comprobación diaria al estar lista la cabina (el motor respeta las 24 h). */
  startup(): Promise<void> {
    return this.run('check', () => this.core.updateCheck(false));
  }

  refresh(): Promise<void> {
    return this.run('', () => this.core.updateState());
  }

  private async run(kind: string, call: () => Promise<unknown>): Promise<void> {
    // Una acción a la vez; la relectura del estado (kind vacío, la que dispara
    // la difusión `update.changed`) no ocupa ni libera el botón.
    if (kind && this.busy) return;
    if (kind) {
      this.busy = kind;
      this.render();
    }
    try {
      const next = await call();
      if (!isUpdateState(next)) throw new Error('el motor devolvió un estado del actualizador ilegible');
      this.error = '';
      this.apply(next);
    } catch (e) {
      this.error = String(e instanceof Error ? e.message : e);
    } finally {
      if (kind) this.busy = '';
      this.render();
    }
  }

  private apply(state: UpdateState): void {
    this.state = state;
    // «No instalar» de esta versión: no se vuelve a pedir en cada refresco.
    if (!state.staged || state.apply_on_exit) this.declined = '';
    const spec = updateAlert(state, this.actions, !!state.staged && this.declined === state.staged.version);
    if (spec) this.alerts.raise(spec);
    else this.alerts.clear('update');
  }

  private render(): void {
    if (!this.host) return;
    if (this.state) renderUpdateSettings(this.host, this.state, this.actions, this.busy);
    else {
      this.host.replaceChildren(el('div', 'card__title', 'Actualizaciones'), el('div', 'card__subtitle', this.busy ? 'Consultando…' : 'Sin estado todavía.'));
    }
    if (this.error) {
      const err = el('div', 'update-bridge-error', `Fallo del actualizador: ${this.error}`);
      err.id = 'update-bridge-error';
      err.setAttribute('role', 'alert');
      err.style.color = 'var(--danger)';
      this.host.append(err);
    }
  }
}

let shared: UpdateController | null = null;

/** El controlador de esta ventana: lo crea main.ts; Ajustes lo reutiliza. */
export function sharedUpdateController(create?: () => UpdateController): UpdateController | null {
  if (!shared && create) shared = create();
  return shared;
}

/**
 * Aviso de esquina. null = no hay nada que avisar (al día, desactivado,
 * error de comprobación: esos se ven en Ajustes, no como alerta).
 */
export function updateAlert(state: UpdateState, actions: UpdateActions, declined = false): AlertSpec | null {
  if (state.staged && stagedIsLatest(state) && state.apply_on_exit) {
    return {
      id: 'update',
      level: 'warn',
      title: `DevAgents ${state.staged.version} lista`,
      body: `Se instalará al cerrar DevAgents, cuando no haya órdenes en curso. ${SIGNATURE_TEXT[state.staged.signature] ?? ''}${state.staged.verified === true ? '' : ' ' + UNVERIFIED_TEXT}`.trim(),
      actions: [{ label: 'No instalar', run: () => actions.applyOnExit(false) }],
    };
  }
  // T12 M3: recién descargada sin firma verificable (aún sin decidir): el
  // aviso lo dice y ofrece el consentimiento expreso.
  if (state.staged && stagedIsLatest(state) && !state.apply_on_exit && state.staged.verified !== true && state.latest && state.status === 'disponible' && !declined) {
    return {
      id: 'update',
      level: 'warn',
      title: `DevAgents ${state.staged.version} descargada`,
      body: UNVERIFIED_TEXT,
      actions: [{ label: 'Instalar al cerrar sin firma verificable', run: () => actions.applyOnExit(true, true) }],
    };
  }
  if (state.status !== 'disponible' || !state.latest || state.staged) return null;
  const latest = state.latest;
  const spec: AlertSpec = {
    id: 'update',
    level: 'warn',
    title: `DevAgents ${latest.version} disponible`,
    body: state.download_error ? `No se pudo preparar: ${state.download_error}` : 'Se descarga y verifica con un clic; se instala al cerrar.',
    actions: [{ label: 'Descargar', run: () => actions.download() }],
  };
  if (latest.notes_url) {
    const url = latest.notes_url;
    spec.actions!.unshift({ label: 'Ver notas', run: () => actions.openNotes(url) });
  }
  return spec;
}
