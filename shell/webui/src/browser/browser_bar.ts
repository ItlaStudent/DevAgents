import type { BridgeClient } from '../bridge/client';
import { SafeHtml, html, joinHtml, raw, setHtml } from '../design/html';
import { icons } from '../design/icons';
import { notice } from '../design/notice';
import {
  BodyKind,
  BrowserEvent,
  BrowserApproval,
  BrowserState,
  BrowserTab,
  activeTab,
  bodyKind,
  breakpointFlags,
  browserEventText,
  controlLabel,
  localAppUrl,
  normalizeAddress,
  sourceLabel,
  tabInitial,
  tabLabel,
  trustLabel,
} from './browser_model';

/**
 * Barra del navegador integrado, pintada por la WebUI de confianza.
 *
 * El host solo aloja la página (un WebView sin puente) justo debajo de esta
 * barra. Aquí no se aprueba nada: cada acción es una orden al host
 * (`browser.*`), que valida con su política; la aprobación de un sitio nuevo
 * llega como petición del host y se responde con un clic en el diálogo. Todo
 * texto que venga de la página (título, URL, origen) entra con `escapeText` o
 * `textContent`, nunca como HTML.
 */

interface HostReply<T> {
  payload?: T;
}

export class BrowserBar {
  private state: BrowserState | null = null;
  private dirty = false;
  private lastStatus = '';
  private dialog: HTMLElement | null = null;
  private dialogFocus: HTMLElement | null = null;
  private answered = new Set<string>();
  private browserEvents = new Set<string>();
  /** Imagen fija de la página que entrega el host cuando una capa de la cabina la pisa. */
  private coverImage = '';
  /** Lo último que se pidió al host con `browser.cover`. */
  private coverAsked = false;
  private readonly surface: HTMLElement;
  private readonly bar: HTMLElement;
  private readonly body: HTMLElement;
  private readonly strip: HTMLElement;
  private readonly address: HTMLInputElement;

  constructor(
    private readonly bridge: BridgeClient,
    private readonly togglePanel: () => void,
  ) {
    const surface = document.getElementById('browser-surface');
    if (!surface) throw new Error('Falta #browser-surface en el esqueleto de la cabina');
    this.surface = surface;
    surface.innerHTML = `
      <div class="bbar" id="browser-bar" role="toolbar" aria-label="Barra del navegador integrado">
        <div class="bbar__tabs">
          <div class="bbar__strip" id="bb-strip" role="tablist" aria-label="Pestañas del navegador"></div>
          <button class="bbar__btn" id="bb-new" type="button" title="Pestaña nueva (Ctrl+T)" aria-label="Pestaña nueva">${icons.plus(15)}</button>
          <button class="bbar__btn bbar__reg" id="bb-control" type="button" title="Sin sesión de agente" aria-label="Sin sesión de agente" disabled>${icons.stop(14)}<span class="bbar__reg-label">Sin sesión de agente</span></button>
          <button class="bbar__btn" id="bb-close" type="button" title="Cerrar el navegador" aria-label="Cerrar el navegador">${icons.close(15)}</button>
        </div>
        <div class="bbar__nav">
          <button class="bbar__btn" id="bb-back" type="button" title="Atrás" aria-label="Atrás">${icons.arrowLeft(16)}</button>
          <button class="bbar__btn" id="bb-forward" type="button" title="Adelante" aria-label="Adelante">${icons.arrowRight(16)}</button>
          <button class="bbar__btn" id="bb-reload" type="button" title="Recargar" aria-label="Recargar">${icons.refresh(15)}</button>
          <form class="bbar__addr" id="bb-form" autocomplete="off">
            <span class="bbar__origin" id="bb-origin" data-trust="none"></span>
            <input class="bbar__input" id="bb-address" type="text" spellcheck="false" autocapitalize="off"
                   aria-label="Dirección" placeholder="Escribe una dirección o un puerto de localhost" />
          </form>
          <button class="bbar__btn bbar__reg" id="bb-register" type="button" title="Registrar la app de este puerto de localhost" aria-label="Registrar app">${icons.localApp(15)}<span class="bbar__reg-label">Registrar app</span></button>
        </div>
        <div class="bbar__progress" id="bb-progress" hidden></div>
      </div>
      <div class="bbody" id="browser-body" aria-live="polite"></div>`;
    this.bar = surface.querySelector('#browser-bar') as HTMLElement;
    this.body = surface.querySelector('#browser-body') as HTMLElement;
    this.strip = surface.querySelector('#bb-strip') as HTMLElement;
    this.address = surface.querySelector('#bb-address') as HTMLInputElement;
    this.wire();
    window.addEventListener('resize', () => this.layoutFlags());
    this.bridge.onPush((topic, payload) => {
      if (topic === 'browser.state') this.apply(payload as BrowserState);
      else if (topic === 'browser.cover') {
        const image = (payload as { image?: unknown } | null)?.image;
        // Solo una imagen JPEG en base64 generada por el host; nunca marcado.
        this.coverImage = typeof image === 'string' && /^data:image\/jpeg;base64,[A-Za-z0-9+/=]+$/.test(image) ? image : '';
        // Llega justo antes del estado con `covered`; si ya está tapada, se pinta ya.
        if (this.state?.covered) this.renderBody();
      }
      else if (topic === 'browser.transport.v1' || /^browser\.(request|started|completed|failed)\.v1$/.test(topic)) {
        const event = payload as Partial<BrowserEvent>;
        if (typeof event?.request_id === 'string' && typeof event.tool === 'string') {
          const state = typeof event.state === 'string' ? event.state : topic.split('.')[1];
          const key = event.request_id + ':' + state + ':' + String(event.code ?? '');
          if (this.browserEvents.has(key)) return;
          this.browserEvents.add(key);
          if (this.browserEvents.size > 256) this.browserEvents.delete(this.browserEvents.values().next().value!);
          const text = browserEventText({ request_id: event.request_id, tool: event.tool, state, elapsed_ms: event.elapsed_ms, code: event.code });
          // Existing notice component: visible live status, no extra layout row
          // covering the native page and no page contents in the event feed.
          notice(text, state === 'failed' ? 'error' : 'info');
          this.bar.dataset.requestId = event.request_id;
          this.bar.dataset.requestState = state;
        }
      }
    });
    this.layoutFlags();
    // La página es una ventana nativa por encima del HTML: si una capa de la
    // cabina la pisa, se le pide al host que la sustituya por su imagen fija.
    window.setInterval(() => this.syncCover(), 120);
    const soon = () => requestAnimationFrame(() => this.syncCover());
    document.addEventListener('pointerdown', soon, true);
    document.addEventListener('keydown', soon, true);
  }

  /** ¿Alguna capa de la cabina (bandeja de avisos, menú, paleta, modal) pisa el rectángulo de la página? */
  private overlapped(): boolean {
    const rect = this.surface.getBoundingClientRect();
    const top = rect.top + this.bar.offsetHeight;
    if (rect.width < 8 || rect.bottom - top < 8) return false;
    for (let y = top + 6; y < rect.bottom - 2; y += 28) {
      for (let x = rect.left + 6; x < rect.right - 2; x += 28) {
        const el = document.elementFromPoint(x, y);
        if (el && !this.surface.contains(el)) return true;
      }
    }
    return false;
  }

  private syncCover(): void {
    const state = this.state;
    const page = !!state && state.open && !state.full && bodyKind(state) === 'page';
    const need = page && this.overlapped();
    if (need === this.coverAsked) return;
    this.coverAsked = need;
    // La imagen anterior no vale para la próxima vez que se tape.
    if (need) this.coverImage = '';
    this.bridge.send('browser.cover', { on: need }).catch(() => {
      // Sin panel no hay nada que tapar; se reintenta en el siguiente ciclo.
      this.coverAsked = !need;
    });
  }

  /** Pide el estado al host; `init` le dice que esta WebUI acaba de arrancar. */
  public async start(): Promise<void> {
    try {
      const reply = await this.bridge.send<{ init: boolean }, HostReply<BrowserState>>('browser.state', { init: true });
      if (reply.payload) this.apply(reply.payload);
    } catch (error) {
      notice('No se pudo leer el estado del navegador: ' + String(error), 'error');
    }
  }

  private call(kind: string, payload: Record<string, unknown> = {}): Promise<boolean> {
    return this.bridge
      .send(kind, payload)
      .then(() => true)
      .catch((error: unknown) => {
        notice(String(error instanceof Error ? error.message : error), 'error');
        return false;
      });
  }

  private wire(): void {
    const $ = <T extends HTMLElement>(id: string) => this.surface.querySelector('#' + id) as T;
    $('bb-new').addEventListener('click', () => void this.call('browser.tab.new'));
    $('bb-control').addEventListener('click', () => {
      if (!this.state || this.state.control_state === 'session_closed') return;
      const action = this.state.control_state === 'user_control' ? 'resume' : 'take';
      // Taking control is visible immediately; resuming waits for host state.
      if (action === 'take') {
        this.state.control_state = 'user_control';
        this.renderControl();
      }
      void this.call('browser.control', { action });
    });
    $('bb-close').addEventListener('click', () => this.togglePanel());
    $('bb-back').addEventListener('click', () => void this.call('browser.back'));
    $('bb-forward').addEventListener('click', () => void this.call('browser.forward'));
    $('bb-reload').addEventListener('click', () => {
      const tab = this.state ? activeTab(this.state) : null;
      void this.call(tab?.loading ? 'browser.stop' : 'browser.reload');
    });
    $('bb-register').addEventListener('click', () => {
      const url = localAppUrl(this.address.value);
      if (!url) return notice('Escribe un puerto de localhost, por ejemplo localhost:3000.', 'info');
      this.dirty = false;
      void this.call('browser.app.register', { url });
    });
    $('bb-form').addEventListener('submit', (event) => {
      event.preventDefault();
      const parsed = normalizeAddress(this.address.value);
      if (!parsed.url) return notice(parsed.error ?? 'Dirección no válida.', 'info');
      this.dirty = false;
      void this.call('browser.navigate', { url: parsed.url });
      this.address.blur();
    });
    this.address.addEventListener('input', () => {
      this.dirty = true;
      this.renderRegister();
    });
    this.address.addEventListener('focus', () => this.address.select());
    this.address.addEventListener('keydown', (event) => {
      if (event.key !== 'Escape') return;
      this.dirty = false;
      this.address.blur();
      this.renderAddress();
    });
    this.strip.addEventListener('click', (event) => {
      const target = event.target as HTMLElement;
      const close = target.closest('[data-close]') as HTMLElement | null;
      if (close) return void this.call('browser.tab.close', { id: Number(close.dataset.close) });
      const tab = target.closest('[data-tab]') as HTMLElement | null;
      if (tab) void this.call('browser.tab.select', { id: Number(tab.dataset.tab) });
    });
    this.strip.addEventListener('auxclick', (event) => {
      const tab = (event.target as HTMLElement).closest('[data-tab]') as HTMLElement | null;
      if (event.button === 1 && tab) void this.call('browser.tab.close', { id: Number(tab.dataset.tab) });
    });
    this.strip.addEventListener('keydown', (event) => {
      const tabs = Array.from(this.strip.querySelectorAll<HTMLElement>('[data-tab]'));
      const index = tabs.findIndex((el) => el === document.activeElement);
      if (index < 0) return;
      let next = index;
      if (event.key === 'ArrowRight') next = (index + 1) % tabs.length;
      else if (event.key === 'ArrowLeft') next = (index - 1 + tabs.length) % tabs.length;
      else if (event.key === 'Home') next = 0;
      else if (event.key === 'End') next = tabs.length - 1;
      else if (event.key === 'Delete') return void this.call('browser.tab.close', { id: Number(tabs[index].dataset.tab) });
      else return;
      event.preventDefault();
      tabs[next].focus();
      void this.call('browser.tab.select', { id: Number(tabs[next].dataset.tab) });
    });
    this.body.addEventListener('click', (event) => {
      const button = (event.target as HTMLElement).closest('button[data-act]') as HTMLButtonElement | null;
      const tab = this.state ? activeTab(this.state) : null;
      if (!button || !tab) return;
      if (button.dataset.act === 'retry') void this.call('browser.reload');
      else if (button.dataset.act === 'dismiss') void this.call('browser.reload');
      // Vuelve a pedir el destino bloqueado SIN quitar el control al agente.
      else if (button.dataset.act === 'approve' && tab.blocked) void this.call('browser.blocked.retry');
      else if (button.dataset.act === 'focus') this.address.focus();
    });
    document.addEventListener('keydown', (event) => {
      if (!this.state?.open || this.state.full) return;
      const key = event.key.toLowerCase();
      if (event.ctrlKey && !event.shiftKey && key === 'l') {
        event.preventDefault();
        this.address.focus();
      } else if (event.ctrlKey && !event.shiftKey && this.surface.contains(document.activeElement) && (key === 't' || key === 'w')) {
        event.preventDefault();
        const tab = activeTab(this.state);
        if (key === 't') void this.call('browser.tab.new');
        else if (tab) void this.call('browser.tab.close', { id: tab.id });
      }
    });
  }

  private apply(state: BrowserState): void {
    const previousControl = this.state?.control_state;
    this.state = state;
    const root = document.documentElement;
    const shell = document.getElementById('beats-app');
    const open = state.open && !state.full && state.panel_px > 0;
    const cssWidth = open ? state.panel_px / (window.devicePixelRatio || 1) : 0;
    root.style.setProperty('--browser-w', cssWidth + 'px');
    root.style.setProperty('--browser-bar-h', state.bar_css + 'px');
    if (shell) shell.dataset.browser = open ? 'open' : 'closed';
    this.surface.hidden = !open;
    this.layoutFlags();
    if (!open) {
      this.renderDialog([]);
      return;
    }
    this.renderTabs();
    this.renderNav();
    this.renderControl();
    this.renderAddress();
    this.renderBody();
    this.renderDialog(state.approvals);
    if (previousControl === 'agent_control' && state.control_state === 'user_control') {
      notice('Has tomado el control del navegador: el agente está en pausa. Pulsa «Reanudar agente» en la barra para que siga.', 'info');
    }
    if (state.status_error && state.status && state.status !== this.lastStatus) notice(state.status, 'error');
    this.lastStatus = state.status;
  }

  private layoutFlags(): void {
    const width = this.state?.open && !this.state.full ? this.state.panel_px / (window.devicePixelRatio || 1) : 0;
    document.documentElement.dataset.bp = breakpointFlags(window.innerWidth, width);
  }

  private renderTabs(): void {
    const state = this.state as BrowserState;
    const hadFocus = this.strip.contains(document.activeElement);
    setHtml(this.strip, joinHtml(state.tabs
      .map((tab) => {
        const selected = tab.id === state.active;
        const label = tabLabel(tab);
        return html`<div class="btab${selected ? ' is-active' : ''}${tab.loading ? ' is-loading' : ''}" role="tab" data-tab="${tab.id}"
                     aria-selected="${selected}" tabindex="${selected ? 0 : -1}" title="${label}${tab.origin ? ' — ' + tab.origin : ''}">
                  <span class="btab__mark" data-trust="${tab.trust}" aria-hidden="true">${tabInitial(tab)}</span>
                  <span class="btab__title">${label}</span>
                  <button class="btab__x" type="button" data-close="${tab.id}" tabindex="-1" aria-label="Cerrar pestaña ${label}">${raw(icons.close(12))}</button>
                </div>`;
      })));
    const active = this.strip.querySelector('.is-active') as HTMLElement | null;
    active?.scrollIntoView?.({ block: 'nearest', inline: 'nearest' });
    if (hadFocus) active?.focus();
  }

  private renderNav(): void {
    const tab = activeTab(this.state as BrowserState);
    const set = (id: string, disabled: boolean) => ((this.surface.querySelector('#' + id) as HTMLButtonElement).disabled = disabled);
    set('bb-back', !tab?.can_back);
    set('bb-forward', !tab?.can_forward);
    set('bb-reload', !tab?.url);
    const reload = this.surface.querySelector('#bb-reload') as HTMLButtonElement;
    const loading = !!tab?.loading;
    setHtml(reload, raw(loading ? icons.stop(14) : icons.refresh(15)));
    reload.title = loading ? 'Detener la carga' : 'Recargar';
    reload.setAttribute('aria-label', reload.title);
    const progress = this.surface.querySelector('#bb-progress') as HTMLElement;
    progress.hidden = !loading;
    this.bar.dataset.loading = String(loading);
  }

  private renderControl(): void {
    const button = this.surface.querySelector('#bb-control') as HTMLButtonElement;
    const state = this.state?.control_state;
    const label = controlLabel(state);
    button.disabled = !state || state === 'session_closed';
    button.title = state === 'user_control' ? 'Control humano: el agente está pausado. Reanudar agente' : label;
    button.setAttribute('aria-label', label);
    button.setAttribute('aria-pressed', String(state === 'user_control'));
    setHtml(button, html`${raw(state === 'user_control' ? icons.play(14) : icons.stop(14))}<span class="bbar__reg-label">${label}</span>`);
    this.bar.dataset.control = state ?? 'session_closed';
  }

  private renderAddress(): void {
    const tab = activeTab(this.state as BrowserState);
    const origin = this.surface.querySelector('#bb-origin') as HTMLElement;
    // Un destino bloqueado se muestra como tal: el sello es del destino que se
    // está pidiendo, no de la página anterior que sigue cargada detrás.
    const blocked = tab?.blocked ?? null;
    const trust = blocked ? 'blocked' : tab?.url ? tab.trust : 'none';
    origin.dataset.trust = trust;
    const label = blocked ? 'Sin aprobar' : tab?.url ? trustLabel(tab.trust) : 'Nueva';
    setHtml(origin, html`${raw(trust === 'none' ? icons.globe(14) : trust === 'fixture' ? icons.file(14) : trust === 'app' ? icons.localApp(14) : icons.shield(14))}<span class="bbar__origin-label">${label}</span>`);
    origin.title = blocked ? `Origen sin aprobar: ${blocked.origin}` : tab?.url ? `${trustLabel(tab.trust)}${tab.origin ? ': ' + tab.origin : ''}` : 'Pestaña vacía';
    if (!this.dirty && document.activeElement !== this.address) this.address.value = tab?.blocked?.url ?? tab?.url ?? '';
    this.renderRegister();
  }

  private renderRegister(): void {
    const reg = this.surface.querySelector('#bb-register') as HTMLButtonElement;
    reg.disabled = !localAppUrl(this.address.value);
  }

  private renderBody(): void {
    const state = this.state as BrowserState;
    const kind: BodyKind = bodyKind(state);
    const tab = activeTab(state);
    // Página tapada por una capa de la cabina: su imagen fija ocupa el sitio
    // de la vista nativa (oculta) y la capa se pinta encima con normalidad.
    const cover = kind === 'page' && !!state.covered;
    this.body.hidden = kind === 'page' && !cover;
    this.body.dataset.kind = cover ? 'cover' : kind;
    this.body.style.backgroundImage = cover && this.coverImage ? `url("${this.coverImage}")` : '';
    if (kind === 'page') {
      this.body.innerHTML = '';
      return;
    }
    // icon/actions/extra son SafeHtml (marcado fijo con raw() o plantillas html``);
    // título y texto son datos y se escapan.
    const card = (icon: SafeHtml, title: string, text: string, actions: SafeHtml | '' = '', extra: SafeHtml | '' = '') =>
      html`<div class="bcard" role="status"><div class="bcard__icon">${icon}</div><h2 class="bcard__title">${title}</h2>
         <p class="bcard__text">${text}</p>${extra}${actions ? html`<div class="bcard__actions">${actions}</div>` : ''}</div>`;
    if (kind === 'starting') {
      setHtml(this.body, card(raw('<span class="bcard__spin" aria-hidden="true"></span>'), 'Iniciando el navegador', state.status || 'Preparando el perfil propio y comprobando el aislamiento de red.'));
    } else if (kind === 'empty') {
      setHtml(this.body, card(
        raw(icons.globe(28)),
        'Nueva pestaña',
        'Escribe una dirección arriba, o registra el puerto de la app que estás construyendo para abrirla aquí.',
        raw('<button class="btn btn--primary" type="button" data-act="focus">Escribir una dirección</button>'),
        raw(`<ul class="bcard__hints"><li><code>localhost:3000</code> y otros puertos locales: botón «Registrar app».</li>
          <li>Sitios externos: se piden por origen y los apruebas tú.</li></ul>`),
      ));
    } else if (kind === 'error' && tab?.error) {
      setHtml(this.body, card(
        raw(icons.alert(28)),
        'No se pudo cargar la página',
        tab.error.reason,
        raw('<button class="btn btn--primary" type="button" data-act="retry">Reintentar</button>'),
        html`<p class="bcard__meta"><code>${tab.origin || tab.url}</code> · ${tab.error.detail || 'código ' + tab.error.code}</p>`,
      ));
    } else if (kind === 'blocked' && tab?.blocked) {
      setHtml(this.body, card(
        raw(icons.shield(28)),
        'Sitio bloqueado por la política',
        tab.blocked.reason,
        raw('<button class="btn btn--primary" type="button" data-act="approve">Aprobar este origen…</button>' +
          '<button class="btn btn--ghost" type="button" data-act="dismiss">Descartar</button>'),
        html`<p class="bcard__meta"><code>${tab.blocked.origin}</code></p>`,
      ));
    } else {
      const origin = state.approvals[0]?.origin ?? '';
      setHtml(this.body, card(raw(icons.shield(28)), 'Esperando tu decisión', 'El navegador no abrirá este sitio hasta que respondas al diálogo de aprobación.', '', html`<p class="bcard__meta"><code>${origin}</code></p>`));
    }
  }

  /** Diálogo de la cabina para aprobar un origen. Escape y perder el foco no aprueban nunca. */
  private renderDialog(approvals: BrowserApproval[]): void {
    for (const id of Array.from(this.answered)) if (!approvals.some((a) => a.id === id)) this.answered.delete(id);
    const pending = approvals.find((a) => !this.answered.has(a.id));
    if (!pending) {
      if (this.dialog) {
        this.dialog.remove();
        this.dialog = null;
        this.dialogFocus?.focus?.();
        this.dialogFocus = null;
      }
      return;
    }
    if (this.dialog?.dataset.request === pending.id) return;
    this.dialog?.remove();
    if (!this.dialogFocus) this.dialogFocus = document.activeElement as HTMLElement | null;
    const overlay = document.createElement('div');
    overlay.className = 'bdlg';
    overlay.dataset.request = pending.id;
    overlay.innerHTML = `
      <div class="bdlg__card" role="alertdialog" aria-modal="true" aria-labelledby="bdlg-title" aria-describedby="bdlg-text">
        <div class="bdlg__head">${icons.shield(18)}<h2 id="bdlg-title">¿Permitir que el navegador abra este sitio?</h2></div>
        <code class="bdlg__origin" id="bdlg-origin"></code>
        <p class="bdlg__by"><strong>Lo pide:</strong> <span id="bdlg-source"></span></p>
        <p class="bdlg__text" id="bdlg-text">Se recordará solo para este origen exacto, en el perfil propio de DevAgents, que no comparte sesiones con tu navegador personal. La página no puede ver ni responder esta pregunta.</p>
        <div class="bdlg__actions">
          <button class="btn" type="button" id="bdlg-no">No</button>
          <button class="btn btn--primary" type="button" id="bdlg-yes">Aprobar origen</button>
        </div>
      </div>`;
    (overlay.querySelector('#bdlg-origin') as HTMLElement).textContent = pending.origin;
    (overlay.querySelector('#bdlg-source') as HTMLElement).textContent = sourceLabel(pending.source);
    const answer = (allow: boolean) => {
      if (this.answered.has(pending.id)) return;
      this.answered.add(pending.id);
      overlay.querySelectorAll('button').forEach((b) => ((b as HTMLButtonElement).disabled = true));
      void this.call('browser.approval.resolve', { request_id: pending.id, allow });
    };
    const no = overlay.querySelector('#bdlg-no') as HTMLButtonElement;
    const yes = overlay.querySelector('#bdlg-yes') as HTMLButtonElement;
    no.addEventListener('click', () => answer(false));
    yes.addEventListener('click', () => answer(true));
    overlay.addEventListener('keydown', (event) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        answer(false);
      } else if (event.key === 'Tab') {
        event.preventDefault();
        (document.activeElement === no ? yes : no).focus();
      }
    });
    overlay.addEventListener('mousedown', (event) => {
      if (event.target === overlay) answer(false);
    });
    document.body.appendChild(overlay);
    this.dialog = overlay;
    no.focus();
  }
}
