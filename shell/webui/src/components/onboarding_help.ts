import { tokens } from '../design/tokens';
import { doctorSummary, isDoctorReport, renderDoctor } from './doctor_view';

/** Lo que el tutorial usa del núcleo (subconjunto de CoreApi). */
interface OnboardingAgent { cli: string; display?: string; session?: string }
interface OnboardingCore {
  getExternalAgents(): Promise<OnboardingAgent[]>;
  refreshExternalAgents(): Promise<OnboardingAgent[]>;
  listKeys(): Promise<Array<{ status?: string }>>;
  discoverModels(): Promise<unknown>;
  modelSelection(): Promise<Array<{ provider: string; model: string }>>;
  onboardingDone?(): Promise<unknown>;
  doctor?(): Promise<unknown>;
}

export class OnboardingModal {
  private container: HTMLElement;
  private currentStep = 1;

  constructor() {
    this.container = document.createElement('div');
    this.container.id = 'onboarding-modal-root';
    this.container.style.cssText = `
      position: fixed; top: 0; left: 0; width: 100vw; height: 100vh;
      background: rgba(0,0,0,0.7); backdrop-filter: blur(4px);
      display: none; align-items: center; justify-content: center;
      z-index: 9999; font-family: ${tokens.typography.fontFamily};
    `;
    document.body.appendChild(this.container);
    this.render();
  }

  public show(): void {
    this.currentStep = 1;
    this.render();
    this.container.style.display = 'flex';
  }

  public hide(): void {
    this.container.style.display = 'none';
  }

  private render(): void {
    this.container.innerHTML = `
      <div style="background:${tokens.color.surface1}; border:1px solid ${tokens.color.accent}; border-radius:12px; width:min(560px, calc(100vw - 32px)); max-height:calc(100vh - 32px); overflow-y:auto; box-sizing:border-box; padding:24px; color:${tokens.color.textPrimary}; box-shadow:0 8px 32px rgba(0,0,0,0.6); display:flex; flex-direction:column; gap:16px;">
        <div style="display:flex; justify-content:space-between; align-items:center;">
          <h2 style="margin:0; font-size:18px; color:${tokens.color.accent};">Bienvenida a DevAgents</h2>
          <span style="font-size:12px; color:${tokens.color.textSecondary};">Paso ${this.currentStep} de 4</span>
        </div>

        <div id="onboarding-step-content" style="min-height:160px; font-size:13px; line-height:1.5;">
          ${this.getStepContent(this.currentStep)}
        </div>

        <div style="display:flex; justify-content:space-between; align-items:center; border-top:1px solid ${tokens.color.border}; padding-top:12px;">
          <button id="btn-onboarding-skip" title="Cerrar el tutorial" style="background:transparent; border:none; color:${tokens.color.textMuted}; cursor:pointer; font-size:12px;">Saltar tutorial</button>
          <div style="display:flex; gap:8px;">
            ${this.currentStep > 1 ? `<button id="btn-onboarding-prev" title="Volver al paso anterior" style="padding:6px 12px; background:${tokens.color.surface2}; color:${tokens.color.textPrimary}; border:none; border-radius:4px; font-size:12px; cursor:pointer;">Anterior</button>` : ''}
            <button id="btn-onboarding-next" title="Avanzar al siguiente paso" style="padding:6px 16px; background:${tokens.color.accent}; color:${tokens.color.accentContrast}; border:none; border-radius:4px; font-weight:600; font-size:12px; cursor:pointer;">
              ${this.currentStep === 4 ? '¡Comenzar!' : 'Siguiente'}
            </button>
          </div>
        </div>
      </div>
    `;

    this.container.querySelector('#btn-onboarding-skip')?.addEventListener('click', () => {
      this.markDone();
      this.hide();
    });
    this.container.querySelector('#btn-onboarding-prev')?.addEventListener('click', () => {
      if (this.currentStep > 1) {
        this.currentStep--;
        this.render();
      }
    });

    this.container.querySelector('#btn-onboarding-next')?.addEventListener('click', () => {
      if (this.currentStep < 4) {
        this.currentStep++;
        this.render();
      } else {
        this.markDone();
        this.hide();
      }
    });
    this.container.querySelectorAll<HTMLButtonElement>('.ob-action').forEach((b) => {
      b.addEventListener('click', () => void this.runAction(b.dataset.action || '', b));
    });
    if (this.currentStep === 1) void this.refreshStatus(false);
  }

  /**
 * (b): «ya visto» se guarda en el motor (sobrevive a una
   * compilación o carpeta del navegador interno nueva); el espejo local se
   * conserva para cuando el motor aún no responde.
   */
  private markDone(): void {
    localStorage.setItem('devagents.onboarded', '1');
    const core = this.core();
    core?.onboardingDone?.().catch((e: unknown) => console.warn('No se pudo guardar que el tutorial ya se vio:', e));
  }

  /** Núcleo expuesto por main.ts; sin él (pruebas) el paso 1 solo informa. */
  private core(): OnboardingCore | null {
    return ((window as unknown as { core?: OnboardingCore }).core) ?? null;
  }

  private setStatus(id: string, text: string, ok?: boolean, segments?: string[]): void {
    const el = this.container.querySelector<HTMLElement>(`#ob-status-${id}`);
    if (!el) return;
    if (segments) {
      // Un span por segmento: el i18n traduce nodo a nodo y un texto unido
      // con « · » solo podría traducirse entero, no cada estado por agente.
      el.textContent = '';
      segments.forEach((seg, i) => {
        if (i > 0) el.append(' · ');
        const span = document.createElement('span');
        span.textContent = seg;
        el.appendChild(span);
      });
    } else {
      el.textContent = text;
    }
    el.style.color = ok === undefined ? tokens.color.textSecondary : ok ? tokens.color.success : tokens.color.warning;
  }

  /** Estado real al abrir el paso 1 (sin lanzar la detección de CLIs). */
  private async refreshStatus(detect: boolean): Promise<void> {
    const core = this.core();
    if (!core) return;
    try {
      const agents = detect ? await core.refreshExternalAgents() : await core.getExternalAgents();
      this.describeAgents(Array.isArray(agents) ? agents : []);
    } catch {
      this.setStatus('agents', 'No se pudo consultar la detección.', false);
    }
    try {
      const keys = await core.listKeys();
      const active = keys.filter((k) => !k.status || k.status === 'active').length;
      this.setStatus('keys', active > 0 ? `${active} clave(s) activa(s).` : 'Todavía no hay ninguna clave.', active > 0);
    } catch { /* sin estado de claves */ }
  }

  private describeAgents(agents: OnboardingAgent[]): void {
    if (!agents.length) {
      this.setStatus('agents', 'No se detectó ninguno instalado en este equipo.', false);
      return;
    }
    const ready = agents.filter((a) => a.session === 'suscripcion' || a.cli === 'opencode');
    const parts = agents.map((a) => {
      const state = a.session === 'suscripcion' ? 'listo' : a.cli === 'opencode' ? 'listo (modelos gratis)' : a.session === 'api_key' ? 'cobraría por API' : 'sin sesión iniciada';
      return `${a.display || a.cli}: ${state}`;
    });
    this.setStatus('agents', parts.join(' · '), ready.length > 0, parts);
  }

  private async runAction(action: string, button: HTMLButtonElement): Promise<void> {
    if (action === 'keys') {
      this.markDone();
      this.hide();
      document.dispatchEvent(new CustomEvent('devagents:settings-section', { detail: 'providers' }));
      return;
    }
    const core = this.core();
    if (!core) return;
    const label = button.textContent || '';
    button.disabled = true;
    button.textContent = 'Comprobando…';
    try {
      if (action === 'agents') {
        await this.refreshStatus(true);
      } else if (action === 'doctor') {
        await this.runDoctor();
      } else if (action === 'local') {
        await core.discoverModels();
        const rows = await core.modelSelection();
        const local = rows.filter((r) => /ollama/i.test(r.provider));
        this.setStatus('local', local.length
          ? `Ollama listo: ${local.length} modelo(s) (${local.slice(0, 3).map((r) => r.model).join(', ')}).`
          : 'No se encontró Ollama. Instálalo, ábrelo, descarga un modelo y vuelve a pulsar.', local.length > 0);
      }
    } catch (e) {
      this.setStatus(action === 'local' ? 'local' : action === 'doctor' ? 'doctor' : 'agents', `No se pudo comprobar: ${String((e as Error)?.message || e)}`, false);
    } finally {
      button.disabled = false;
      button.textContent = label;
    }
  }

  /** Tanda 4: `doctor` en el tutorial; enseña solo lo que hay que arreglar. */
  private async runDoctor(): Promise<void> {
    const core = this.core();
    if (!core?.doctor) {
      this.setStatus('doctor', 'Este motor no ofrece la comprobación.', false);
      return;
    }
    const report = await core.doctor();
    if (!isDoctorReport(report)) throw new Error('respuesta inválida del motor');
    this.setStatus('doctor', doctorSummary(report), report.ready);
    const list = this.container.querySelector<HTMLElement>('#ob-doctor-list');
    if (list) renderDoctor(list, report, true);
  }

  private getStepContent(step: number): string {
    switch (step) {
      case 1: {
        const card = `background:${tokens.color.surface2}; border:1px solid ${tokens.color.border}; border-radius:8px; padding:9px 11px; display:flex; flex-direction:column; gap:5px;`;
        const btn = `align-self:flex-start; padding:4px 10px; background:transparent; color:${tokens.color.accent}; border:1px solid ${tokens.color.accent}; border-radius:5px; font-size:11px; cursor:pointer;`;
        const status = `font-size:11px; color:${tokens.color.textSecondary};`;
        return `
          <h3 style="margin-top:0; color:${tokens.color.accent};">1. Elige con qué IA trabajar</h3>
          <p style="margin:0 0 8px;">Necesitas <b>al menos una</b> de estas tres. Puedes comprobarlas aquí mismo:</p>
          <div style="display:flex; flex-direction:column; gap:8px;">
            <div style="${card}">
              <b>Agentes que ya usas (con tu suscripción)</b>
              <span>Claude Code, Codex, Gemini CLI u OpenCode. Deben estar <b>instalados y con la sesión iniciada</b> en tu terminal: DevAgents no los instala ni cobra por ellos.</span>
              <button type="button" class="ob-action" data-action="agents" style="${btn}">Detectar agentes</button>
              <span id="ob-status-agents" style="${status}"></span>
            </div>
            <div style="${card}">
              <b>Una clave API</b>
              <span>Gemini, OpenRouter, Claude, Groq… Varias tienen plan gratuito (marcadas «gratis» en la lista).</span>
              <button type="button" class="ob-action" data-action="keys" style="${btn}">Añadir una clave</button>
              <span id="ob-status-keys" style="${status}"></span>
            </div>
            <div style="${card}">
              <b>Modelos locales (gratis, sin internet)</b>
              <span>Requiere <b>Ollama</b> instalado y abierto (ollama.com) y un modelo descargado, por ejemplo <code>ollama pull qwen2.5:7b</code>. Sin GPU dedicada pueden tardar varios minutos en contestar.</span>
              <button type="button" class="ob-action" data-action="local" style="${btn}">Buscar modelos locales</button>
              <span id="ob-status-local" style="${status}"></span>
            </div>
            <div style="${card}">
              <b>Este equipo</b>
              <span>Comprueba la carpeta de datos, el espacio en disco, WebView2, git y la sesión de cada agente, sin lanzar ninguna orden.</span>
              <button type="button" class="ob-action" data-action="doctor" style="${btn}">Comprobar este equipo</button>
              <span id="ob-status-doctor" style="${status}"></span>
              <div id="ob-doctor-list" style="font-size:11px;"></div>
            </div>
          </div>
        `;
      }
      case 2:
        return `
          <h3 style="margin-top:0; color:${tokens.color.accent};">2. Abre tu carpeta</h3>
          <p>En el panel derecho, <b>Entorno › Cambiar la carpeta de trabajo</b>. En Directo, la IA edita esa carpeta como en cualquier IDE, con los permisos que elijas.</p>
        `;
      case 3:
        return `
          <h3 style="margin-top:0; color:${tokens.color.accent};">3. Escribe como en cualquier IDE</h3>
          <p>Por defecto trabajas en <b>Directo</b>: un solo modelo conversa contigo, lee y edita tu proyecto y ejecuta lo necesario. Lo que escribe aparece en <b>Resultados</b>. Usa <code>@</code> para adjuntar archivos y <code>/</code> para comandos.</p>
        `;
      case 4:
        return `
          <h3 style="margin-top:0; color:${tokens.color.accent};">4. Cuando quieras más</h3>
          <p>En <b>Modos</b>: <b>Orquestado</b> planifica, reparte el trabajo y hace que <b>otro fabricante revise</b> lo que hizo el primero; <b>Colmena</b> lo reparte entre varios modelos en paralelo. El coste se controla en Configuración › Gobernanza (Solo gratis, Híbrido o Prioriza pago).</p>
        `;
      default:
        return '';
    }
  }
}

export class HelpPanel {
  private container: HTMLElement;

  constructor() {
    this.container = document.createElement('div');
    this.container.id = 'help-panel-root';
    this.container.style.cssText = `
      position: fixed; top: 40px; right: 20px; width: 380px; max-height: 520px;
      background: ${tokens.color.surface1}; border: 1px solid ${tokens.color.borderStrong};
      border-radius: 8px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); z-index: 8000;
      display: none; flex-direction: column; padding: 14px; font-family: ${tokens.typography.fontFamily};
    `;
    document.body.appendChild(this.container);
    this.render();
  }

  private anchor: HTMLElement | null = null;
  private readonly onOutside = (e: MouseEvent): void => {
    const t = e.target as Node | null;
    if (!t || this.container.contains(t) || (this.anchor && this.anchor.contains(t))) return;
    this.hide();
  };
  private readonly onKey = (e: KeyboardEvent): void => {
    if (e.key === 'Escape') this.hide();
  };

  public isOpen(): boolean {
    return this.container.style.display !== 'none';
  }

  /**
 * propietario (10-nov): la ayuda se abría pegada a la esquina superior derecha
   * aunque se pidiera desde el pie del panel izquierdo. Ahora sale junto al
   * botón que la pidió (a su derecha, alineada con él) y sin anclaje, como
   * antes. Un segundo clic en el mismo botón la cierra.
   */
  public show(anchor?: HTMLElement | null): void {
    if (this.isOpen() && anchor && anchor === this.anchor) {
      this.hide();
      return;
    }
    this.anchor = anchor ?? null;
    this.container.style.display = 'flex';
    this.place();
    document.addEventListener('mousedown', this.onOutside, true);
    document.addEventListener('keydown', this.onKey, true);
    (this.container.querySelector('#help-search-input') as HTMLInputElement | null)?.focus();
  }

  public hide(): void {
    this.container.style.display = 'none';
    document.removeEventListener('mousedown', this.onOutside, true);
    document.removeEventListener('keydown', this.onKey, true);
  }

  private place(): void {
    const s = this.container.style;
    const anchor = this.anchor && this.anchor.isConnected ? this.anchor : null;
    if (!anchor) {
      s.top = '40px'; s.right = '20px'; s.left = 'auto'; s.bottom = 'auto';
      this.container.style.transformOrigin = 'top right';
      return;
    }
    const r = anchor.getBoundingClientRect();
    const w = this.container.offsetWidth || 380;
    const h = this.container.offsetHeight || 420;
    const gap = 8;
    // A la derecha del botón si cabe; si no, a su izquierda.
    let left = r.right + gap;
    if (left + w > window.innerWidth - gap) left = Math.max(gap, r.left - gap - w);
    // Alineada por abajo con el botón (los botones de ayuda viven abajo),
    // sin salirse de la ventana.
    let top = r.bottom - h;
    top = Math.max(gap, Math.min(top, window.innerHeight - h - gap));
    s.left = `${Math.round(left)}px`; s.top = `${Math.round(top)}px`;
    s.right = 'auto'; s.bottom = 'auto';
    this.container.style.transformOrigin = left > r.left ? 'bottom left' : 'bottom right';
  }

  private render(): void {
    this.container.innerHTML = `
      <div style="display:flex; justify-content:space-between; align-items:center; border-bottom:1px solid ${tokens.color.border}; padding-bottom:8px; margin-bottom:10px;">
        <span style="font-weight:700; font-size:14px; color:${tokens.color.accent};">Panel de ayuda y preguntas frecuentes</span>
        <button id="btn-close-help" title="Cerrar la ayuda" style="background:transparent; border:none; color:${tokens.color.textSecondary}; font-size:16px; cursor:pointer;">&times;</button>
      </div>

      <input type="text" id="help-search-input" placeholder="Buscar ayuda (ej: menciones, clave, espacios)..." style="width:100%; box-sizing:border-box; background:${tokens.color.bgMain}; border:1px solid ${tokens.color.border}; color:${tokens.color.textPrimary}; padding:6px 10px; border-radius:4px; font-size:12px; margin-bottom:10px;" />

      <div id="help-topics-list" style="flex:1; overflow-y:auto; display:flex; flex-direction:column; gap:8px; font-size:12px;">
        <div class="help-item" style="padding:6px; background:${tokens.color.surface2}; border-radius:4px;">
          <div style="font-weight:600; color:${tokens.color.accent};">¿Cómo usar @-menciones?</div>
          <div style="color:${tokens.color.textSecondary}; margin-top:2px;">Escribe @ en el compositor para listar archivos, o @symbol: para autocompletar funciones y clases del servidor de lenguaje.</div>
        </div>

        <div class="help-item" style="padding:6px; background:${tokens.color.surface2}; border-radius:4px;">
          <div style="font-weight:600; color:${tokens.color.accent};">¿Qué son los Spaces?</div>
          <div style="color:${tokens.color.textSecondary}; margin-top:2px;">Entornos de trabajo aislados basados en Git Worktrees que evitan modificar tu directorio principal directamente.</div>
        </div>

        <div class="help-item" style="padding:6px; background:${tokens.color.surface2}; border-radius:4px;">
          <div style="font-weight:600; color:${tokens.color.accent};">Atajos de Teclado Rápido</div>
          <div style="color:${tokens.color.textSecondary}; margin-top:2px;">
            <code>Ctrl+P</code>: Paleta de Comandos<br>
            <code>Ctrl+S</code>: Guardar archivo<br>
            <code>Ctrl+O</code>: Abrir archivo
          </div>
        </div>
      </div>

      <div style="border-top:1px solid ${tokens.color.border}; padding-top:10px; margin-top:10px; display:flex; align-items:center; gap:8px;">
        <button id="btn-diag-download" title="Genera un informe con el estado del motor y la bitácora de consola de esta sesión" style="flex:1; padding:7px 10px; background:${tokens.color.surface2}; color:${tokens.color.textPrimary}; border:1px solid ${tokens.color.borderStrong}; border-radius:6px; font-size:12px; cursor:pointer;">Descargar diagnóstico</button>
        <button id="btn-help-doctor" title="Comprueba datos, disco, WebView2, git y la sesión de cada agente, sin lanzar ninguna orden" style="padding:7px 10px; background:transparent; color:${tokens.color.textSecondary}; border:1px solid ${tokens.color.borderStrong}; border-radius:6px; font-size:12px; cursor:pointer;">Comprobar equipo</button>
        <button id="btn-help-tutorial" title="Vuelve a mostrar el tutorial de bienvenida de 4 pasos" style="padding:7px 10px; background:transparent; color:${tokens.color.textSecondary}; border:1px solid ${tokens.color.borderStrong}; border-radius:6px; font-size:12px; cursor:pointer;">Repetir tutorial</button>
        <span style="font-size:10px; color:${tokens.color.textMuted}; max-width:150px;">Incluye errores de consola y estado del motor. Sin claves ni contenido de mensajes.</span>
      </div>
    `;

    this.container.querySelector('#btn-close-help')?.addEventListener('click', () => this.hide());
    this.container.querySelector('#btn-help-tutorial')?.addEventListener('click', () => {
      this.hide();
      window.dispatchEvent(new CustomEvent('devagents:show-onboarding'));
    });
    this.container.querySelector('#btn-diag-download')?.addEventListener('click', () => {
      void this.downloadDiagnostics();
    });
    this.container.querySelector('#btn-help-doctor')?.addEventListener('click', () => {
      void this.showDoctor();
    });
    const searchInput = this.container.querySelector('#help-search-input') as HTMLInputElement;

    searchInput?.addEventListener('input', () => {
      const q = searchInput.value.toLowerCase();
      this.container.querySelectorAll('.help-item').forEach((item) => {
        const text = (item as HTMLElement).innerText.toLowerCase();
        (item as HTMLElement).style.display = text.includes(q) ? 'block' : 'none';
      });
    });
  }

  /**
   * E2.16 — informe de diagnóstico descargable. Reúne el estado del motor
   * (versión, órdenes, permisos) y la bitácora de errores de consola que
   * `main.ts` guarda en `window.__devagentsLog`. No incluye claves, mensajes
   * del usuario ni rutas internas sensibles: el informe se puede pegar en un
   * reporte de fallo sin filtrar nada.
   */
  /** Tanda 4: el informe de `doctor` dentro del panel, en lugar de los temas. */
  private async showDoctor(): Promise<void> {
    const list = this.container.querySelector<HTMLElement>('#help-topics-list');
    const btn = this.container.querySelector<HTMLButtonElement>('#btn-help-doctor');
    if (!list || !btn) return;
    const core = (window as { core?: { doctor?: () => Promise<unknown> } }).core;
    btn.disabled = true;
    btn.textContent = 'Comprobando…';
    try {
      if (!core?.doctor) throw new Error('el motor no ofrece la comprobación');
      const report = await core.doctor();
      if (!isDoctorReport(report)) throw new Error('respuesta inválida del motor');
      const summary = document.createElement('div');
      summary.id = 'help-doctor-summary';
      summary.textContent = doctorSummary(report);
      summary.style.cssText = `font-weight:600; color:${report.ready ? tokens.color.success : tokens.color.warning}; padding-bottom:4px;`;
      const rows = document.createElement('div');
      renderDoctor(rows, report, false);
      list.replaceChildren(summary, rows);
    } catch (e) {
      const msg = document.createElement('div');
      msg.textContent = `No se pudo comprobar: ${String((e as Error)?.message || e)}`;
      list.replaceChildren(msg);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Comprobar equipo';
    }
  }

  private async downloadDiagnostics(): Promise<void> {
    const btn = this.container.querySelector<HTMLButtonElement>('#btn-diag-download');
    if (btn) {
      btn.disabled = true;
      btn.textContent = 'Generando…';
    }
    try {
      const lineas: string[] = [
        '# Diagnóstico DevAgents',
        `Fecha: ${new Date().toISOString()}`,
        `Agente: ${navigator.userAgent}`,
        `Ventana: ${window.innerWidth}x${window.innerHeight} @${window.devicePixelRatio}x`,
        `Tema: ${window.localStorage.getItem('devagents.theme') || 'desconocido'}`,
        '',
        '## Estado del motor',
      ];
      const core = (window as { core?: { status?: () => Promise<unknown> } }).core;
      if (core?.status) {
        try {
          lineas.push('```json', JSON.stringify(await core.status(), null, 2), '```');
        } catch (e) {
          lineas.push(`No respondió: ${String(e)}`);
        }
      } else {
        lineas.push('Sin conexión con el motor (core no expuesto).');
      }
      const doctorCore = (window as { core?: { doctor?: () => Promise<unknown> } }).core;
      if (doctorCore?.doctor) {
        lineas.push('', '## Comprobación del equipo (doctor)');
        try {
          lineas.push('```json', JSON.stringify(await doctorCore.doctor(), null, 2), '```');
        } catch (e) {
          lineas.push(`No respondió: ${String(e)}`);
        }
      }
      lineas.push('', '## Bitácora de consola de la sesión');
      const log = ((window as { __devagentsLog?: Array<{ ts: string; level: string; text: string }> }).__devagentsLog) ?? [];
      if (!log.length) {
        lineas.push('(sin errores ni avisos de consola en esta sesión)');
      } else {
        for (const entrada of log) lineas.push(`[${entrada.ts}] ${entrada.level}: ${entrada.text}`);
      }
      const texto = lineas.join('\n');
      const blob = new Blob([texto], { type: 'text/plain;charset=utf-8' });
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `devagents-diag-${new Date().toISOString().replace(/[:.]/g, '-')}.txt`;
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 5000);
    } finally {
      if (btn) {
        btn.disabled = false;
        btn.textContent = 'Descargar diagnóstico';
      }
    }
  }
}
