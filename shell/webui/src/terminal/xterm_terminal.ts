import { escapeText as esc } from '../design/html';
import { CoreApi } from '../bridge/core_api';
import { icons } from '../design/icons';
import type { BridgeClient } from '../bridge/client';

interface TerminalSession {
  terminalId: number;
  shellPath: string;
  cols: number;
  rows: number;
  running: boolean;
  mode: 'conpty' | 'pipes';
}

/**
 * Terminal ConPTY real montada en el panel inferior sobre xterm.js vendored
 * (ADR-B012, vendor/xterm). Interpreta de verdad las secuencias ANSI —
 * colores, cursor, pantalla completa — y manda las teclas a la ConPTY por
 * onData→ptyWrite. Si el vendor UMD no está cargado (window.Terminal
 * ausente), cae al emulador simple con parser ANSI propio: mismo shell, misma
 * API, menos fidelidad de terminal.
 */

const POLL_MS = 400;
/**
 * 11-nov (propietario: «la terminal escribe lento, muy lento»): el eco de cada tecla
 * esperaba al siguiente sondeo de 400 ms. Tras escribir o mientras llega
 * salida, se sondea a ritmo de fotograma; en reposo se vuelve a 400 ms.
 */
const POLL_FAST_MS = 16;
const FAST_WINDOW_MS = 1500;
/** Tamaño de la letra de la terminal: el mismo cuerpo de 12 px que el resto del panel. */
const TERMINAL_FONT_PX = 12;
const HISTORY_MAX = 50;

// Secuencias OSC: `ESC ] … BEL` o `ESC ] … ESC \`. cmd.exe manda una nada mas
// arrancar para fijar el titulo de la ventana, asi que sin esto la primera
// linea que ve el usuario es basura de escape en crudo.
const OSC_RE = /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g;
// Escapes de un solo caracter que quedan sueltos (ESC = , ESC > , ESC ( B …).
const ESC_SIMPLE_RE = /\x1b[()#][0-9A-Za-z]|\x1b[=>78Mc]/g;



export interface AnsiState {
  fg: string | null;
  bg: string | null;
  bold: boolean;
  dim: boolean;
  italic: boolean;
  underline: boolean;
}

const FG_MAP: Record<number, string> = {
  30: '#4b5563',
  31: 'var(--danger)',
  32: 'var(--success)',
  33: 'var(--warning)',
  34: 'var(--accent)',
  35: '#d946ef',
  36: '#06b6d4',
  37: 'var(--fg)',
  90: '#6b7280',
  91: '#f87171',
  92: '#4ade80',
  93: '#fde047',
  94: '#60a5fa',
  95: '#f472b6',
  96: '#22d3ee',
  97: '#ffffff',
};

const BG_MAP: Record<number, string> = {
  40: '#1f2937',
  41: 'rgba(239, 68, 68, 0.25)',
  42: 'rgba(34, 197, 94, 0.25)',
  43: 'rgba(234, 179, 8, 0.25)',
  44: 'rgba(59, 130, 246, 0.25)',
  45: 'rgba(217, 70, 239, 0.25)',
  46: 'rgba(6, 182, 212, 0.25)',
  47: '#e5e7eb',
  100: '#374151',
  101: 'rgba(248, 113, 113, 0.35)',
  102: 'rgba(74, 222, 128, 0.35)',
  103: 'rgba(253, 224, 71, 0.35)',
  104: 'rgba(96, 165, 250, 0.35)',
  105: 'rgba(244, 114, 182, 0.35)',
  106: 'rgba(34, 211, 238, 0.35)',
  107: '#ffffff',
};

export function ansiToHtml(input: string, state: AnsiState): { html: string; state: AnsiState } {
  // Limpiar secuencias OSC, escapes simples y secuencias de cursor no-SGR (todo excepto 'm')
  const clean = input
    .replace(OSC_RE, '')
    .replace(ESC_SIMPLE_RE, '')
    .replace(/\x1b\[[0-9;?]*[a-ln-zA-Z]/g, '');
  const parts = clean.split(/(\x1b\[[0-9;]*m)/g);
  let out = '';

  for (const part of parts) {
    if (!part) continue;
    const match = part.match(/^\x1b\[([0-9;]*)m$/);
    if (match) {
      const codes = match[1] ? match[1].split(';').map((c) => parseInt(c, 10)) : [0];
      let i = 0;
      while (i < codes.length) {
        const code = codes[i];
        if (isNaN(code) || code === 0) {
          state.fg = null;
          state.bg = null;
          state.bold = false;
          state.dim = false;
          state.italic = false;
          state.underline = false;
        } else if (code === 1) {
          state.bold = true;
        } else if (code === 2) {
          state.dim = true;
        } else if (code === 3) {
          state.italic = true;
        } else if (code === 4) {
          state.underline = true;
        } else if (code === 22) {
          state.bold = false;
          state.dim = false;
        } else if (code === 23) {
          state.italic = false;
        } else if (code === 24) {
          state.underline = false;
        } else if (code === 39) {
          state.fg = null;
        } else if (code === 49) {
          state.bg = null;
        } else if (FG_MAP[code]) {
          state.fg = FG_MAP[code];
        } else if (BG_MAP[code]) {
          state.bg = BG_MAP[code];
        } else if (code === 38 && codes[i + 1] === 5 && codes[i + 2] !== undefined) {
          state.fg = 'var(--accent)';
          i += 2;
        } else if (code === 48 && codes[i + 1] === 5 && codes[i + 2] !== undefined) {
          state.bg = 'rgba(59, 130, 246, 0.2)';
          i += 2;
        } else if (code === 38 && codes[i + 1] === 2 && codes[i + 4] !== undefined) {
          state.fg = `rgb(${codes[i + 2]}, ${codes[i + 3]}, ${codes[i + 4]})`;
          i += 4;
        } else if (code === 48 && codes[i + 1] === 2 && codes[i + 4] !== undefined) {
          state.bg = `rgb(${codes[i + 2]}, ${codes[i + 3]}, ${codes[i + 4]})`;
          i += 4;
        }
        i++;
      }
    } else {
      const escaped = esc(part);
      const styles: string[] = [];
      if (state.fg) styles.push(`color:${state.fg}`);
      if (state.bg) styles.push(`background-color:${state.bg}`);
      if (state.bold) styles.push(`font-weight:bold`);
      if (state.dim) styles.push(`opacity:0.7`);
      if (state.italic) styles.push(`font-style:italic`);
      if (state.underline) styles.push(`text-decoration:underline`);

      if (styles.length > 0) {
        out += `<span style="${styles.join(';')}">${escaped}</span>`;
      } else {
        out += escaped;
      }
    }
  }

  return { html: out, state };
}

export class XtermTerminal {
  private container: HTMLElement;
  private core: CoreApi;

  private terminalId = 0;
  private offset = 0;
  private pollHandle: ReturnType<typeof setTimeout> | null = null;
  private lastActivity = 0;
  private splitLastActivity = 0;
  private running = false;
  private startedAt = 0;
  private shellPath = 'cmd.exe';
  private starting: Promise<void> | null = null;
  private generation = 0;
  private reading = false;
  private sessions: TerminalSession[] = [];
  private readonly onStopRequest = (): void => this.stop();
  private readonly onStateRequest = (): void => this.emitState();

  private history: string[] = [];
  private historyPos = -1;

  private ansiState: AnsiState = {
    fg: null,
    bg: null,
    bold: false,
    dim: false,
    italic: false,
    underline: false,
  };

  private outputEl!: HTMLElement;
  private inputEl!: HTMLInputElement;
  private statusPillEl!: HTMLElement;
  private shellLabelEl!: HTMLElement;

  /** Instancia real de xterm.js cuando el vendor UMD está cargado. */
  private xterm: any = null;
  private fitAddon: any = null;
  private xtermHost!: HTMLElement;

  // Panel secundario de la división: su propia sesión, su propio sondeo y su
  // propio host. Deshacer la división no toca ninguna PTY: solo retira la vista.
  private splitTerminalId = 0;
  private splitOffset = 0;
  private splitPollHandle: ReturnType<typeof setTimeout> | null = null;
  private splitRunning = false;
  private splitReading = false;
  private splitGeneration = 0;
  private splitOutputEl: HTMLElement | null = null;
  private splitInputEl: HTMLInputElement | null = null;
  private splitXterm: any = null;
  private splitFitAddon: any = null;
  private splitResizeObserver: ResizeObserver | null = null;
  /** Guarda de reentrada de split(): un solo montaje y un solo spawn en vuelo. */
  private splitting = false;
  private splitAnsiState: AnsiState = {
    fg: null,
    bg: null,
    bold: false,
    dim: false,
    italic: false,
    underline: false,
  };

  constructor(container: HTMLElement, core: CoreApi) {
    this.container = container;
    this.core = core;
    this.renderShell();
    this.initXterm();
    document.addEventListener('devagents:terminal-stop', this.onStopRequest);
    document.addEventListener('devagents:terminal-state-request', this.onStateRequest);
  }

  private emitState(): void {
    document.dispatchEvent(
      new CustomEvent('devagents:terminal-state', {
        detail: { running: this.running, terminalId: this.terminalId, startedAt: this.startedAt },
      })
    );
  }

  /**
   * Monta xterm.js sobre #term-output si el vendor está presente. El <pre>
   * con el parser ANSI propio queda debajo como fallback (ADR-B012 §4).
   * El tema se deriva de las CSS vars de la cabina y sigue a ThemeManager.
   */
  private initXterm(): void {
    const w = window as any;
    if (!w.Terminal || !this.xtermHost) return;
    const cssVar = (n: string, fb: string) =>
      getComputedStyle(document.documentElement).getPropertyValue(n).trim() || fb;
    const themeFromVars = () => ({
      background: cssVar('--bg-main', '#0a0a0a'),
      foreground: cssVar('--fg', '#e5e7eb'),
      cursor: cssVar('--accent', '#00d68f'),
      cursorAccent: cssVar('--bg-main', '#0a0a0a'),
      selectionBackground: cssVar('--accent-soft', '#00d68f44'),
      black: cssVar('--fg-subtle', '#6b7280'),
      red: cssVar('--danger', '#f87171'),
      green: cssVar('--success', '#4ade80'),
      yellow: cssVar('--warning', '#fde047'),
      blue: cssVar('--accent', '#60a5fa'),
      magenta: '#f472b6',
      cyan: '#22d3ee',
      white: cssVar('--fg', '#e5e7eb'),
    });
    try {
      const fontFamily = cssVar('--font-code', 'Consolas, monospace');
      this.xterm = new w.Terminal({
        cursorBlink: true,
        fontSize: TERMINAL_FONT_PX,
        fontFamily,
        theme: themeFromVars(),
        convertEol: false,
      });
      if (w.FitAddon?.FitAddon) {
        this.fitAddon = new w.FitAddon.FitAddon();
        this.xterm.loadAddon(this.fitAddon);
      }
      this.xterm.open(this.xtermHost);
      this.fitAddon?.fit();
      this.xterm.onData((data: string) => {
        if (this.running && this.terminalId) {
          void this.core.ptyWrite(this.terminalId, data).then(() => this.kick(), () => {});
        }
      });
      // La pseudoconsola escribe con el cursor en posiciones absolutas: si
      // cree que mide 80 columnas y el panel mide 36, pisa filas.
      this.xterm.onResize(({ cols, rows }: { cols: number; rows: number }) => this.enviaTamano(cols, rows));
      this.outputEl.style.display = 'none';
      new ResizeObserver(() => { try { this.fitAddon?.fit(); } catch { /* panel oculto */ } }).observe(this.xtermHost);
      new MutationObserver(() => { if (this.xterm) this.xterm.options.theme = themeFromVars(); })
        .observe(document.documentElement, { attributes: true, attributeFilter: ['style'] });
    } catch {
      this.xterm = null;
      this.outputEl.style.display = '';
    }
  }

  // --- Ciclo de vida ---------------------------------------------------------

  public start(workingDir = '', createNew = false): Promise<void> {
    return this.connect(workingDir, createNew);
  }

  private connect(workingDir: string, createNew: boolean, selectedId?: number): Promise<void> {
    if (this.starting) return this.starting;
    if (this.running && !createNew && selectedId === undefined) return Promise.resolve();
    this.starting = this.openSession(workingDir, createNew, selectedId).finally(() => { this.starting = null; });
    return this.starting;
  }

  private async openSession(workingDir: string, createNew: boolean, selectedId?: number): Promise<void> {
    // Cambiar de sesión no debe dejar un panel dividido apuntando a la anterior.
    this.unsplit();
    const generation = ++this.generation;
    this.stopPolling();
    this.running = false;
    this.setStatus(false, 'Iniciando…');
    try {
      // main.ts exposes the existing BridgeClient. Reuse it: a second client
      // would reuse message ids and consume responses belonging to CoreApi.
      const bridge = (window as unknown as { bridgeClient: BridgeClient }).bridgeClient;
      const listed = await bridge.send<{ list: boolean }, { payload: { terminals: TerminalSession[] } }>('pty.read', { list: true });
      if (generation !== this.generation) return;
      this.sessions = listed.payload.terminals.filter(session => session.running)
        .sort((a, b) => a.terminalId - b.terminalId);
      const existing = selectedId === undefined ? this.sessions[0] : this.sessions.find(session => session.terminalId === selectedId);
      if (selectedId !== undefined && !existing) throw new Error('La sesión de terminal ya no está viva.');
      const res = !createNew && existing ? existing : await this.core.ptySpawn(this.shellPath, workingDir);
      if (generation !== this.generation) {
        if (createNew || !existing) await this.core.ptyKill(res.terminalId);
        return;
      }
      if (createNew || !existing) {
        this.sessions.push({ terminalId: res.terminalId, shellPath: this.shellPath, cols: 80, rows: 25,
          running: true, mode: res.mode ?? 'conpty' });
      }
      this.terminalId = res.terminalId;
      this.offset = 0;
      this.running = true;
      this.startedAt = Date.now();
      this.clearSessionOutput();
      this.shellLabelEl.innerText = !createNew && existing ? existing.shellPath : this.shellPath;
      const primaryPane = this.container.querySelector<HTMLElement>('#term-pane');
      if (primaryPane) primaryPane.dataset.terminalId = String(this.terminalId);
      this.renderSessions();
      // se anuncia la vía REAL. Antes decía «ConPTY» siempre, también
      // cuando el host había caído al respaldo por tuberías.
      if (res.mode === 'pipes') {
        this.setStatus(true, 'Conectado · tuberías');
        this.appendSystemLine(
          `Terminal por tuberías (id ${this.terminalId}): la pseudoconsola no respondió. ` +
            'Los comandos funcionan; sin colores, sin redimensionar y sin programas a pantalla completa.'
        );
      } else {
        this.setStatus(true, 'Conectado');
        this.appendSystemLine(`Sesion ConPTY ${!createNew && existing ? 'reconectada' : 'iniciada'} (id ${this.terminalId}).`);
      }
      // One channel for replay and live data: read byte offset 0, then use the
      // exact offset returned by the host. Never derive it from JS string length.
      await this.pollOnce();
      if (generation !== this.generation || !this.running) return;
      this.startPolling();
      if (this.xterm) {
        try { this.fitAddon?.fit(); } catch { /* panel aún sin tamaño */ }
        // onResize solo salta si el tamaño CAMBIA; el primero se manda aquí,
        // que es cuando ya hay terminalId.
        this.enviaTamano(this.xterm.cols, this.xterm.rows);
        this.xterm.focus();
      }
      this.emitState();
    } catch (err) {
      if (generation !== this.generation) return;
      this.running = false;
      this.startedAt = 0;
      this.setStatus(false, 'Detenido');
      this.appendErrorLine(String(err instanceof Error ? err.message : err));
      this.emitState();
    }
  }

  private enviaTamano(cols: number, rows: number): void {
    if (!this.running || !this.terminalId || !cols || !rows) return;
    void this.core.ptyResize(this.terminalId, cols, rows).catch(() => {});
  }

  public stop(): void {
    this.unsplit();
    ++this.generation;
    this.stopPolling();
    if (this.running && this.terminalId) {
      void this.core.ptyKill(this.terminalId).catch(() => {});
    }
    this.running = false;
    this.startedAt = 0;
    this.setStatus(false, 'Detenido');
    this.emitState();
  }

  public isRunning(): boolean {
    return this.running;
  }

  public isSplit(): boolean {
    return this.splitTerminalId !== 0;
  }

  /**
   * Abre un segundo panel con OTRA sesión PTY. Si no hay una segunda sesión
   * viva, la crea; si el backend no puede, devuelve false y no cambia nada.
   * Las dos PTY siguen en `sessions`: dividir es una vista, no un ciclo de vida.
   */
  public async split(): Promise<boolean> {
    if (this.isSplit()) return true;
    if (this.splitting) return false;
    if (!this.running || !this.terminalId) return false;
    const primaryId = this.terminalId;
    const generation = ++this.splitGeneration;
    const isCurrent = () => generation === this.splitGeneration && this.running && this.terminalId === primaryId;
    let spawnedId = 0;
    let retained = false;
    this.splitting = true;
    try {
      let session = this.sessions.find(item => item.terminalId !== primaryId);
      if (!session) {
        let res: { terminalId: number; mode?: 'conpty' | 'pipes' };
        try {
          res = await this.core.ptySpawn(this.shellPath, '');
        } catch {
          return false;
        }
        if (!res || !res.terminalId || res.terminalId === primaryId) return false;
        spawnedId = res.terminalId;
        // Tras el await hay que revalidar: si el usuario paró, cambió de sesión
        // o deshizo la división mientras se creaba la PTY, no se monta el panel
        // y la sesión nueva se mata para no dejarla huérfana.
        if (!isCurrent()) return false;
        session = {
          terminalId: res.terminalId,
          shellPath: this.shellPath,
          cols: 80,
          rows: 25,
          running: true,
          mode: res.mode ?? 'conpty',
        };
      }
      if (!session || !isCurrent()) return false;
      const panes = this.container.querySelector('#term-panes');
      if (!panes) return false;
      const pane = document.createElement('div');
      pane.className = 'col term-pane';
      pane.id = 'term-pane-2';
      pane.dataset.terminalId = String(session.terminalId);
      pane.style.cssText = 'flex:1 1 0;min-width:0;min-height:0;border-left:1px solid var(--border)';
      pane.innerHTML = `
      <div class="row" style="justify-content:space-between;padding:2px 8px;border-bottom:1px solid var(--border);flex:0 0 auto">
        <span class="subtle mono">${esc(session.shellPath)} · ${session.terminalId}</span>
        <button class="icon-btn" id="term-btn-unsplit" title="Cerrar la vista dividida" aria-label="Cerrar la vista dividida">×</button>
      </div>
      <div class="grow" style="position:relative;min-height:0">
        <div id="term-output-2" style="position:absolute;inset:0"></div>
        <pre class="code-surface scroll-y" id="term-output-plain-2" style="position:absolute;inset:0;margin:0;padding:8px 10px;white-space:pre-wrap;word-break:break-word"></pre>
      </div>
      <div class="row" style="padding:6px 8px;border-top:1px solid var(--border);flex:0 0 auto">
        <input class="input mono" id="term-input-2" placeholder="Escribe un comando…" />
      </div>
    `;
      panes.appendChild(pane);
      this.splitOutputEl = pane.querySelector<HTMLElement>('#term-output-plain-2');
      this.splitInputEl = pane.querySelector<HTMLInputElement>('#term-input-2');
      this.splitAnsiState = { fg: null, bg: null, bold: false, dim: false, italic: false, underline: false };
      this.splitTerminalId = session.terminalId;
      this.splitOffset = 0;
      this.splitRunning = true;
      pane.querySelector('#term-btn-unsplit')?.addEventListener('click', () => this.unsplit());
      this.splitInputEl?.addEventListener('keydown', (ev) => void this.onSplitInputKeydown(ev));
      this.initSplitXterm(pane.querySelector<HTMLElement>('#term-output-2'));
      const splitStatus = session.mode === 'pipes' ? ' · tuberías' : '';
      this.appendSplitRaw(`[terminal] Panel dividido: sesion ${session.terminalId}${splitStatus}\n`);
      try {
        await this.pollSplitOnce();
      } catch {
        /* la sesión recién creada aún no tiene salida */
      }
      if (!isCurrent()) return false;
      // La PTY nueva solo pasa a ser persistente al completar esta operación.
      if (spawnedId) {
        this.sessions.push(session);
        this.renderSessions();
        retained = true;
      }
      if (!this.splitRunning) return true;
      this.startSplitPolling();
      this.splitFitAddon?.fit?.();
      return true;
    } finally {
      if (spawnedId && !retained) {
        try {
          await this.core.ptyKill(spawnedId);
        } catch (err) {
          this.appendErrorLine(`No se pudo cerrar la PTY ${spawnedId}: ${String(err instanceof Error ? err.message : err)}`);
        }
      }
      if (generation === this.splitGeneration) this.splitting = false;
    }
  }

  /**
   * Retira el segundo panel y su sondeo. NO mata la PTY ni la quita de
   * `sessions`: se puede volver a ver con el selector o con otra división.
   */
  public unsplit(): void {
    ++this.splitGeneration;
    this.splitting = false;
    this.stopSplitPolling();
    this.splitRunning = false;
    this.splitReading = false;
    this.splitTerminalId = 0;
    this.splitOffset = 0;
    try { this.splitXterm?.dispose?.(); } catch { /* vendor sin dispose */ }
    this.splitXterm = null;
    this.splitFitAddon = null;
    try { this.splitResizeObserver?.disconnect(); } catch { /* ya desconectado */ }
    this.splitResizeObserver = null;
    this.splitOutputEl = null;
    this.splitInputEl = null;
    this.splitAnsiState = { fg: null, bg: null, bold: false, dim: false, italic: false, underline: false };
    this.container.querySelector('#term-pane-2')?.remove();
  }

  private initSplitXterm(host: HTMLElement | null): void {
    const w = window as any;
    if (!host || !w.Terminal) return;
    try {
      const cssVar = (name: string, fallback: string) =>
        getComputedStyle(document.documentElement).getPropertyValue(name).trim() || fallback;
      this.splitXterm = new w.Terminal({
        cursorBlink: true,
        fontSize: TERMINAL_FONT_PX,
        fontFamily: cssVar('--font-code', 'Consolas, monospace'),
        theme: {
          background: cssVar('--bg-main', '#0a0a0a'),
          foreground: cssVar('--fg', '#e5e7eb'),
          cursor: cssVar('--accent', '#00d68f'),
          cursorAccent: cssVar('--bg-main', '#0a0a0a'),
        },
        convertEol: false,
      });
      if (w.FitAddon?.FitAddon) {
        this.splitFitAddon = new w.FitAddon.FitAddon();
        this.splitXterm.loadAddon(this.splitFitAddon);
      }
      this.splitXterm.open(host);
      this.splitXterm.onData((data: string) => {
        if (this.splitRunning && this.splitTerminalId) {
          void this.core.ptyWrite(this.splitTerminalId, data).then(() => this.kickSplit(), () => {});
        }
      });
      this.splitXterm.onResize(({ cols, rows }: { cols: number; rows: number }) => {
        if (this.splitRunning && this.splitTerminalId && cols && rows) {
          void this.core.ptyResize(this.splitTerminalId, cols, rows).catch(() => {});
        }
      });
      if (this.splitOutputEl) this.splitOutputEl.style.display = 'none';
      this.splitResizeObserver = new ResizeObserver(() => { try { this.splitFitAddon?.fit(); } catch { /* panel oculto */ } });
      this.splitResizeObserver.observe(host);
    } catch {
      this.splitXterm = null;
      this.splitFitAddon = null;
    }
  }

  private async onSplitInputKeydown(ev: KeyboardEvent): Promise<void> {
    if (this.splitInputEl && XtermTerminal.isInterrupt(ev, this.splitInputEl)) {
      ev.preventDefault();
      this.splitInputEl.value = '';
      if (this.splitRunning && this.splitTerminalId) {
        await this.core.ptyWrite(this.splitTerminalId, '\x03').catch(() => {});
        this.kickSplit();
      }
      return;
    }
    if (ev.key !== 'Enter' || !this.splitInputEl) return;
    const text = this.splitInputEl.value;
    this.splitInputEl.value = '';
    if (!this.splitRunning || !this.splitTerminalId) {
      this.appendSplitRaw('[terminal] No hay una sesion activa en este panel.\n');
      return;
    }
    try {
      await this.core.ptyWrite(this.splitTerminalId, text + '\r\n');
      this.kickSplit();
    } catch (err) {
      this.appendSplitRaw(`[terminal] ${String(err instanceof Error ? err.message : err)}\n`);
    }
  }

  /**
   * Manda una orden a la terminal como si el usuario la hubiera escrito.
   *
   * Es lo que permite el boton "Ejecutar" del panel de Cambios: lanzar desde
   * aqui, y no por el executor del motor, es lo que hace que un programa con
   * ventana siga vivo despues de que la orden termine.
   */
  public async runCommand(command: string): Promise<boolean> {
    if (!this.running || !this.terminalId) {
      try {
        await this.start();
      } catch {
        return false;
      }
    }
    if (!this.running || !this.terminalId) return false;
    try {
      await this.core.ptyWrite(this.terminalId, command + '\r\n');
      this.kick();
      this.history.push(command);
      if (this.history.length > HISTORY_MAX) this.history.shift();
      return true;
    } catch {
      return false;
    }
  }

  public clear(): void {
    if (this.xterm) {
      this.xterm.clear();
      return;
    }
    this.outputEl.textContent = '';
    this.ansiState = {
      fg: null,
      bg: null,
      bold: false,
      dim: false,
      italic: false,
      underline: false,
    };
  }

  private clearSessionOutput(): void {
    this.xterm?.reset();
    this.outputEl.textContent = '';
    this.ansiState = { fg: null, bg: null, bold: false, dim: false, italic: false, underline: false };
  }

  private renderSessions(): void {
    const select = this.container.querySelector<HTMLSelectElement>('#term-session');
    if (!select) return;
    select.innerHTML = this.sessions.map(session =>
      `<option value="${session.terminalId}">${esc(session.shellPath)} · ${session.terminalId}</option>`).join('');
    select.value = String(this.terminalId);
  }

  // --- UI ----------------------------------------------------------------

  private renderShell(): void {
    this.container.innerHTML = `
      <div class="col" style="height:100%;min-height:0">
        <div class="row" style="justify-content:space-between;padding:4px 8px;border-bottom:1px solid var(--border);flex:0 0 auto">
          <div class="row" style="gap:8px">
            <span class="pill" id="term-status-pill"><span class="pill__dot"></span><span>Detenido</span></span>
            <span class="subtle mono" id="term-shell-label">cmd.exe</span>
            <select id="term-session" class="input mono" aria-label="Sesión de terminal"></select>
          </div>
          <div class="row" style="gap:2px">
            <button class="icon-btn" id="term-btn-split" title="Dividir terminal" aria-label="Dividir terminal">▥</button>
            <button class="icon-btn" id="term-btn-clear" title="Limpiar salida">${icons.trash(14)}</button>
            <button class="icon-btn" id="term-btn-new" title="Nueva terminal" aria-label="Nueva terminal">+</button>
            <button class="icon-btn" id="term-btn-restart" title="Reiniciar terminal">${icons.refresh(14)}</button>
          </div>
        </div>
        <div id="term-panes" class="row" style="flex:1;min-height:0;overflow:hidden">
          <div class="col term-pane" id="term-pane" data-terminal-id="" style="flex:1 1 0;min-width:0;min-height:0">
            <!-- #term-output es el host de xterm.js (su DOM interno sigue dando
                 textContent legible a las sondas). #term-output-plain es el
                 fallback con el parser ANSI propio. -->
            <div class="grow" style="position:relative;min-height:0">
              <div id="term-output" style="position:absolute;inset:0"></div>
              <pre class="code-surface scroll-y" id="term-output-plain" style="position:absolute;inset:0;margin:0;padding:8px 10px;white-space:pre-wrap;word-break:break-word"></pre>
            </div>
            <div class="row" style="padding:6px 8px;border-top:1px solid var(--border);flex:0 0 auto">
              <input class="input mono" id="term-input" placeholder="Escribe un comando y pulsa Enter…" />
            </div>
          </div>
        </div>
      </div>
    `;

    this.xtermHost = this.container.querySelector('#term-output')!;
    this.outputEl = this.container.querySelector('#term-output-plain')!;
    this.inputEl = this.container.querySelector<HTMLInputElement>('#term-input')!;
    this.statusPillEl = this.container.querySelector('#term-status-pill')!;
    this.shellLabelEl = this.container.querySelector('#term-shell-label')!;
    this.shellLabelEl.innerText = this.shellPath;

    this.inputEl.addEventListener('keydown', (ev) => void this.onInputKeydown(ev));

    this.container.querySelector('#term-btn-split')?.addEventListener('click', () => void this.split());
    this.container.querySelector('#term-btn-clear')?.addEventListener('click', () => this.clear());
    this.container.querySelector('#term-btn-new')?.addEventListener('click', () => void this.start('', true));
    this.container.querySelector<HTMLSelectElement>('#term-session')?.addEventListener('change', (event) => {
      void this.connect('', false, Number((event.target as HTMLSelectElement).value));
    });
    this.container.querySelector('#term-btn-restart')?.addEventListener('click', () => {
      this.stop();
      void this.start('', true);
    });
  }

  /**
   * Ctrl+C en la caja de comandos: sin texto seleccionado interrumpe el
   * proceso (^C, como en cualquier terminal); con selección sigue copiando.
   */
  private static isInterrupt(ev: KeyboardEvent, el: HTMLInputElement): boolean {
    if (!ev.ctrlKey || ev.altKey || ev.metaKey || ev.shiftKey) return false;
    if ((ev.key || '').toLowerCase() !== 'c') return false;
    const start = el.selectionStart ?? 0;
    const end = el.selectionEnd ?? 0;
    return start === end;
  }

  private async onInputKeydown(ev: KeyboardEvent): Promise<void> {
    if (XtermTerminal.isInterrupt(ev, this.inputEl)) {
      ev.preventDefault();
      this.inputEl.value = '';
      if (this.running && this.terminalId) {
        await this.core.ptyWrite(this.terminalId, '\x03').catch(() => {});
        this.kick();
      }
      return;
    }
    if (ev.key === 'Enter') {
      const text = this.inputEl.value;
      this.inputEl.value = '';
      if (text.trim()) {
        this.history.push(text);
        if (this.history.length > HISTORY_MAX) this.history.shift();
      }
      this.historyPos = -1;
      if (!this.running || !this.terminalId) {
        this.appendErrorLine('No hay una sesion de terminal activa.');
        return;
      }
      try {
        await this.core.ptyWrite(this.terminalId, text + '\r\n');
        this.kick();
      } catch (err) {
        this.appendErrorLine(String(err instanceof Error ? err.message : err));
      }
      return;
    }
    if (ev.key === 'ArrowUp') {
      if (!this.history.length) return;
      ev.preventDefault();
      this.historyPos = this.historyPos < 0 ? this.history.length - 1 : Math.max(0, this.historyPos - 1);
      this.inputEl.value = this.history[this.historyPos] ?? '';
      return;
    }
    if (ev.key === 'ArrowDown') {
      if (!this.history.length) return;
      ev.preventDefault();
      if (this.historyPos < 0) return;
      this.historyPos += 1;
      if (this.historyPos >= this.history.length) {
        this.historyPos = -1;
        this.inputEl.value = '';
      } else {
        this.inputEl.value = this.history[this.historyPos] ?? '';
      }
    }
  }

  // --- Sondeo --------------------------------------------------------------

  /** Sondeo autoprogramado: rápido con actividad reciente, lento en reposo. */
  private startPolling(): void {
    this.stopPolling();
    const tick = async (): Promise<void> => {
      this.pollHandle = null;
      await this.pollOnce();
      if (!this.running || this.pollHandle !== null) return;
      const fast = Date.now() - this.lastActivity < FAST_WINDOW_MS;
      this.pollHandle = setTimeout(() => void tick(), fast ? POLL_FAST_MS : POLL_MS);
    };
    this.pollHandle = setTimeout(() => void tick(), POLL_MS);
    this.pollTick = tick;
  }
  private pollTick: (() => Promise<void>) | null = null;
  private splitPollTick: (() => Promise<void>) | null = null;

  /** Tras escribir: leer YA el eco en vez de esperar al siguiente sondeo lento. */
  private kick(): void {
    this.lastActivity = Date.now();
    if (!this.running || !this.pollTick) return;
    if (this.pollHandle !== null) clearTimeout(this.pollHandle);
    this.pollHandle = setTimeout(() => void this.pollTick?.(), 0);
  }

  private kickSplit(): void {
    this.splitLastActivity = Date.now();
    if (!this.splitRunning || !this.splitPollTick) return;
    if (this.splitPollHandle !== null) clearTimeout(this.splitPollHandle);
    this.splitPollHandle = setTimeout(() => void this.splitPollTick?.(), 0);
  }

  private stopPolling(): void {
    if (this.pollHandle !== null) {
      clearTimeout(this.pollHandle);
      this.pollHandle = null;
    }
    this.pollTick = null;
  }

  private startSplitPolling(): void {
    this.stopSplitPolling();
    const tick = async (): Promise<void> => {
      this.splitPollHandle = null;
      await this.pollSplitOnce();
      if (!this.splitRunning || this.splitPollHandle !== null) return;
      const fast = Date.now() - this.splitLastActivity < FAST_WINDOW_MS;
      this.splitPollHandle = setTimeout(() => void tick(), fast ? POLL_FAST_MS : POLL_MS);
    };
    this.splitPollHandle = setTimeout(() => void tick(), POLL_MS);
    this.splitPollTick = tick;
  }

  private stopSplitPolling(): void {
    if (this.splitPollHandle !== null) {
      clearTimeout(this.splitPollHandle);
      this.splitPollHandle = null;
    }
    this.splitPollTick = null;
  }

  private async pollSplitOnce(): Promise<void> {
    if (!this.splitRunning || !this.splitTerminalId || this.splitReading) return;
    const generation = this.splitGeneration;
    const id = this.splitTerminalId;
    this.splitReading = true;
    try {
      const res = await this.core.ptyRead(id, this.splitOffset);
      if (generation !== this.splitGeneration || !this.splitRunning) return;
      this.splitOffset = res.offset;
      if (res.data) { this.splitLastActivity = Date.now(); this.appendSplitRaw(res.data); }
    } catch (err) {
      if (generation !== this.splitGeneration) return;
      this.stopSplitPolling();
      this.splitRunning = false;
      this.appendSplitRaw(`[terminal] ${String(err instanceof Error ? err.message : err)}\n`);
    } finally {
      if (generation === this.splitGeneration) this.splitReading = false;
    }
  }

  private async pollOnce(): Promise<void> {
    if (!this.running || !this.terminalId || this.reading) return;
    const generation = this.generation;
    const id = this.terminalId;
    this.reading = true;
    try {
      const res = await this.core.ptyRead(id, this.offset);
      if (generation !== this.generation) return;
      this.offset = res.offset;
      if (res.data) { this.lastActivity = Date.now(); this.appendRaw(res.data); }
    } catch (err) {
      if (generation !== this.generation) return;
      this.stopPolling();
      this.running = false;
      this.startedAt = 0;
      this.setStatus(false, 'Detenido');
      this.appendErrorLine(String(err instanceof Error ? err.message : err));
      this.emitState();
    } finally {
      this.reading = false;
    }
  }

  // --- Salida ----------------------------------------------------------------

  private isScrolledToBottom(): boolean {
    const el = this.outputEl;
    return el.scrollHeight - el.scrollTop - el.clientHeight < 24;
  }

  private appendRaw(text: string): void {
    if (this.xterm) {
      this.xterm.write(text);
      return;
    }
    const wasAtBottom = this.isScrolledToBottom();
    const { html, state } = ansiToHtml(text, this.ansiState);
    this.ansiState = state;
    if (html) {
      const span = document.createElement('span');
      span.innerHTML = html;
      this.outputEl.appendChild(span);
    }
    if (wasAtBottom) this.outputEl.scrollTop = this.outputEl.scrollHeight;
  }

  private appendSplitRaw(text: string): void {
    if (this.splitXterm) {
      this.splitXterm.write(text);
      return;
    }
    if (!this.splitOutputEl) return;
    const { html, state } = ansiToHtml(text, this.splitAnsiState);
    this.splitAnsiState = state;
    if (!html) return;
    const span = document.createElement('span');
    span.innerHTML = html;
    this.splitOutputEl.appendChild(span);
    this.splitOutputEl.scrollTop = this.splitOutputEl.scrollHeight;
  }

  private appendSystemLine(text: string): void {
    this.appendRaw(`[terminal] ${text}\n`);
  }

  private appendErrorLine(text: string): void {
    if (this.xterm) {
      this.xterm.write(`\x1b[31m[terminal] ${text}\x1b[0m\n`);
      return;
    }
    const wasAtBottom = this.isScrolledToBottom();
    const span = document.createElement('span');
    span.style.color = 'var(--danger)';
    span.textContent = `[terminal] ${text}\n`;
    this.outputEl.appendChild(span);
    if (wasAtBottom) this.outputEl.scrollTop = this.outputEl.scrollHeight;
  }

  private setStatus(online: boolean, label: string): void {
    this.statusPillEl.classList.toggle('pill--online', online);
    this.statusPillEl.classList.toggle('pill--offline', !online);
    const span = this.statusPillEl.querySelector('span:last-child');
    if (span) span.textContent = label;
  }
}
