import { tokens } from '../design/tokens';
import { escapeText } from '../design/html';
import { BridgeClient } from '../bridge/client';
import { highlight, langFor, Lang } from './highlight';
import { notice } from '../design/notice';
import { icons } from '../design/icons';
import { confirmModal, promptModal } from '../design/modal';
import { pareceBinario } from './binario';
import { aHex } from './monaco_color';
import { monacoLanguageFor, registerProjectLanguages } from './monaco_language';
import { fileActionsMarkup, fileActionButtons, syncFileActions } from './file_actions';

export interface EditorOptions {
  readOnly?: boolean;
  language?: string;
  theme?: 'dark' | 'light';
}

// --- Monaco real, vendorizado offline (ADR-B012) --------------------------
// El AMD build de Monaco vive en vendor/monaco (min/vs del paquete npm) y se
// carga perezoso la primera vez que se monta el editor. Si la carga falla —
// vendor ausente en un despliegue recortado, CSP más estricta, error de red
// virtual — el editor cae al textarea superpuesto de siempre, que sigue
// montado debajo y conserva toda su lógica. Los dos modos comparten la API
// pública y la lógica de fichero (buffers, dirty, conflicto de disco).
declare const require: any;
declare const monaco: any;

let monacoLoaderPromise: Promise<any | null> | null = null;

function loadMonaco(): Promise<any | null> {
  if (monacoLoaderPromise) return monacoLoaderPromise;
  monacoLoaderPromise = new Promise((resolve) => {
    const w = window as any;
    if (w.monaco?.editor && w.monaco.languages.getLanguages().some((language: any) => language.id === 'html')) {
      resolve(w.monaco); return;
    }
    const s = document.createElement('script');
    s.src = 'vendor/monaco/loader.js';
    s.onload = () => {
      try {
        const req = (w as any).require;
        req.config({ paths: { vs: 'vendor/monaco' } });
        // 0.56 separates syntax registrations from editor.main. The grammar
        // files existing on disk is insufficient: this contribution loads them.
        req(['vs/editor/editor.main', 'vs/basic-languages/monaco.contribution'], () => resolve(w.monaco ?? null), () => {
          notice('No se pudo cargar el resaltado de Monaco; se usa el editor simple.', 'error');
          resolve(null);
        });
      } catch {
        notice('No se pudo iniciar Monaco; se usa el editor simple.', 'error');
        resolve(null);
      }
    };
    s.onerror = () => {
      notice('No se pudo cargar Monaco; se usa el editor simple.', 'error');
      resolve(null);
    };
    document.head.appendChild(s);
  });
  return monacoLoaderPromise;
}

/** Valor resuelto de una custom property de :root (la paleta DevAgents). */
const cssVar_ = (name: string, fallback: string): string => {
  const v = getComputedStyle(document.documentElement).getPropertyValue(name).trim();
  return v || fallback;
};

/** Var de :root como color que Monaco acepta; el fallback si no se puede. */
const hex = (name: string, fallback: string): string => aHex(cssVar_(name, '')) ?? fallback;

/** `#rrggbb` + alfa hex. Si el var no es un color opaco legible, usa el fallback. */
const withAlpha = (name: string, alpha: string, fallback: string): string => {
  const v = aHex(cssVar_(name, ''));
  return v && v.length === 7 ? v + alpha : fallback;
};

const lumOf = (hex: string): number => {
  const m = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})/i.exec(hex.trim());
  if (!m) return 0;
  return (0.2126 * parseInt(m[1], 16) + 0.7152 * parseInt(m[2], 16) + 0.0722 * parseInt(m[3], 16)) / 255;
};

/** Var resuelta a '#rrggbb' sin la almohadilla (las rules de Monaco la exigen). */
const col = (name: string, fallback: string): string => {
  const v = cssVar_(name, fallback).trim();
  const hexM = /^#([0-9a-fA-F]{6})/.exec(v);
  if (hexM) return hexM[1];
  const rgbM = /rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)/.exec(v);
  if (rgbM) return [rgbM[1], rgbM[2], rgbM[3]].map((n) => (+n).toString(16).padStart(2, '0')).join('');
  return fallback.replace('#', '');
};

/**
 * El tema «devagents» deriva de la paleta de la cabina (las CSS vars que escribe
 * ThemeManager), no de los colores stock de Monaco — el editor tiene que
 * parecer DevAgents, no VS Code. Se redefine cuando las vars cambian.
 *
 * Las rules replican el resaltado propio (highlight.ts): keywords=accent
 * negrita, cadenas=success, comentarios=fg-subtle itálica, números=warning,
 * claves JSON/tipos=accent-2, funciones=info. Cada rol conserva el pigmento
 * de la cabina en temas oscuros y claros; identificadores/delimitadores=fg.
 */
function applyBeatsTheme(m: any): void {
  const bg = hex('--bg-main', '#0a0a0a');
  const fg = col('--fg', '#eceff4');
  const accent = col('--accent', '#88c0d0');
  const accent2 = col('--accent-2', accent);
  const success = col('--success', '#a3be8c');
  const subtle = col('--fg-subtle', '#616e88');
  const warning = col('--warning', '#ebcb8b');
  const info = col('--info', '#6389a6');
  const rules = [
      { token: 'keyword', foreground: accent, fontStyle: 'bold' },
      { token: 'keyword.type', foreground: accent2 },
      { token: 'string', foreground: success },
      { token: 'string.escape', foreground: success },
      { token: 'comment', foreground: subtle, fontStyle: 'italic' },
      { token: 'number', foreground: warning },
      { token: 'number.hex', foreground: warning },
      { token: 'number.binary', foreground: warning },
      { token: 'number.octal', foreground: warning },
      { token: 'key', foreground: accent2 },
      { token: 'string.key.json', foreground: accent2 },
      { token: 'string.value.json', foreground: success },
      { token: 'keyword.json', foreground: accent, fontStyle: 'bold' },
      { token: 'identifier', foreground: fg },
      { token: 'type', foreground: accent2 },
      { token: 'type.identifier', foreground: accent2 },
      { token: 'function', foreground: info },
      { token: 'variable', foreground: fg },
      { token: 'variable.predefined', foreground: info },
      { token: 'attribute.name', foreground: accent2 },
      { token: 'attribute.value', foreground: success },
      { token: 'attribute.value.number', foreground: warning },
      { token: 'tag', foreground: accent },
      { token: 'delimiter', foreground: fg },
      { token: 'operator', foreground: fg },
      { token: 'namespace', foreground: accent2 },
      { token: 'predefined', foreground: info },
  ];
  // Stock themes contain string.sql, operator.sql, delimiter.html, etc.
  // Their more specific scopes override generic rules unless qualified too.
  const scopes = new Set<string>([
    ...m.languages.getLanguages().map((language: any) => language.id), 'js', 'ts', 'zig', 'toml',
  ]);
  m.editor.defineTheme('devagents', {
    base: lumOf(bg) < 0.5 ? 'vs-dark' : 'vs',
    inherit: true,
    rules: rules.flatMap(rule => [rule, ...[...scopes].map(scope => ({ ...rule, token: `${rule.token}.${scope}` }))]),
    colors: {
      'editor.background': bg,
      'editor.foreground': hex('--fg', '#e5e7eb'),
      'editorGutter.background': bg,
      'editorLineNumber.foreground': hex('--fg-subtle', '#6b7280'),
      'editorLineNumber.activeForeground': hex('--fg', '#e5e7eb'),
      'editorCursor.foreground': hex('--accent', '#00d68f'),
      'editor.selectionBackground': withAlpha('--accent', '55', '#00d68f55'),
      'editor.inactiveSelectionBackground': withAlpha('--accent', '2e', '#00d68f2e'),
      'editor.lineHighlightBackground': hex('--surface-1', '#15171c'),
      'editor.lineHighlightBorder': '#00000000',
      'editorWidget.background': hex('--surface-2', '#1a1d24'),
      'editorWidget.border': hex('--border', '#2a2e38'),
      'editorSuggestWidget.background': hex('--surface-2', '#1a1d24'),
      'editorSuggestWidget.border': hex('--border', '#2a2e38'),
      'editorSuggestWidget.selectedBackground': withAlpha('--accent', '33', '#00d68f33'),
      'editorHoverWidget.background': hex('--surface-2', '#1a1d24'),
      'editorHoverWidget.border': hex('--border', '#2a2e38'),
      'editorBracketMatch.background': withAlpha('--accent', '22', '#00d68f22'),
      'editorBracketMatch.border': hex('--accent', '#00d68f'),
      'editorIndentGuide.background1': hex('--border', '#2a2e38'),
      'editorWhitespace.foreground': hex('--border', '#2a2e38'),
      'scrollbarSlider.background': withAlpha('--fg-subtle', '44', '#6b728044'),
      'scrollbarSlider.hoverBackground': withAlpha('--fg-subtle', '66', '#6b728066'),
      'focusBorder': hex('--accent', '#00d68f'),
      // 22-09: diagnósticos y resaltado de Unicode con los pigmentos de la
      // paleta, no con el rojo y el naranja de VS Code.
      'editorError.foreground': hex('--danger', '#c4553d'),
      'editorWarning.foreground': hex('--warning', '#c89246'),
      'editorInfo.foreground': hex('--info', '#6389a6'),
      'editorUnicodeHighlight.border': withAlpha('--warning', '66', '#c8924666'),
      'editorUnicodeHighlight.background': '#00000000',
    },
  });
  m.editor.setTheme('devagents');
}

export class MonacoEditor {
  private container: HTMLElement;
  private content: string = '';
  /**
   * Ruta del archivo abierto. Es la ÚNICA fuente de verdad de «hay archivo»
 *: Canvas/Diff se repintan desde ella en `setFilePath`, que es
   * por donde pasa todo cambio, así que no hay un flag aparte que desincronizar.
   */
  private filePath: string = '';
  /** Botones Canvas/Diff de la cabecera; los crea `render()`. */
  private fileActionEls?: HTMLButtonElement[];

  private setFilePath(path: string): void {
    this.filePath = path;
    if (this.fileActionEls) syncFileActions(this.fileActionEls, path);
  }
  private language: string = 'typescript';
  private lineNumbersElem!: HTMLElement;
  private codeAreaElem!: HTMLTextAreaElement;
  private statusLineElem!: HTMLElement;
  private bridge: BridgeClient;
  private onChangeCallbacks: Array<(text: string) => void> = [];

  /** Instancia real de Monaco cuando el vendor cargó; null = modo fallback. */
  private monacoEd: any = null;
  private wordWrap = false;
  private minimapEnabled = false;
  private saveAllQueue?: Promise<void>;
  private settingValue = false;
  private splitOwner: MonacoEditor | null = null;
  private splitEditor: MonacoEditor | null = null;
  private themeObserver?: MutationObserver;
  private openRequest = 0;
  public onFocus: ((editor: MonacoEditor) => void) | null = null;

  /**
   * Gancho del Ctrl+Enter «autocompletar desde comentario» (main.ts). En modo
   * fallback la tecla llega sola al listener global; con Monaco hay que
   * interceptarla porque el editor la liga a InsertLineBelow.
   */
  public onCtrlEnter: (() => void) | null = null;

  /** Canvas y Diff: main.ts los cablea; solo se llaman con archivo abierto. */
  public onOpenCanvas: (() => void) | null = null;
  public onReviewDiff: (() => void) | null = null;

  constructor(container: HTMLElement, bridge: BridgeClient, options: EditorOptions = {}) {
    this.container = container;
    this.bridge = bridge;
    this.language = options.language || 'typescript';
    this.render();
    this.container.addEventListener('focusin', (event) => {
      // El secundario está dentro del contenedor raíz: su foco no lo roba el padre.
      if (this.splitEditor?.container.contains(event.target as Node)) return;
      (this.splitOwner ?? this).onFocus?.(this);
    });
    void this.initMonaco();
  }

  /**
   * Intenta montar Monaco real sobre la superficie del editor. Si el vendor
   * AMD no carga, no toca nada: el textarea superpuesto queda como editor.
   */
  private async initMonaco(): Promise<void> {
    const m = await loadMonaco();
    if (!m || !this.container.isConnected) return;
    const host = this.container.querySelector<HTMLElement>('#editor-monaco-host');
    const plain = this.container.querySelector<HTMLElement>('#editor-plain-surface');
    if (!host || !plain) return;
    try {
      applyBeatsTheme(m);
      registerProjectLanguages(m);
      this.monacoEd = m.editor.create(host, {
        value: this.content,
        language: this.language,
        theme: 'devagents',
        automaticLayout: true,
        fontSize: 13,
        fontFamily: getComputedStyle(document.documentElement).getPropertyValue('--font-code') || 'Consolas, monospace',
        wordWrap: this.wordWrap ? 'on' : 'off',
        minimap: { enabled: this.minimapEnabled },
        tabSize: 2,
        insertSpaces: true,
        // El editor propio no coloreaba parejas de paréntesis; desactivado
        // para que el aspecto quede como estaba (paréntesis en --fg).
        bracketPairColorization: { enabled: false },
      });
      // En 0.56 la opción del editor no llega al modelo: el flag real de la
      // colorización de parejas vive en el TextModel. Sin esto los paréntesis
      // salen dorados (bracket-highlighting-0) aunque la opción diga false.
      this.monacoEd.getModel()?.updateOptions({ bracketColorizationOptions: { enabled: false } });
      this.monacoEd.onDidChangeModelContent(() => {
        if (this.settingValue) return;
        this.content = this.monacoEd.getValue();
        this.notifyChange();
      });
      this.monacoEd.onDidChangeCursorPosition(() => this.updateCursorStatus());
      // Ctrl+S en fase CAPTURA sobre el host: llega antes que los handlers
      // internos de Monaco (que usa EditContext y puede tragarse la tecla),
      // corta la burbuja hacia el listener global de main.ts y guarda UNA vez
      // — el mismo invariante que el stopPropagation del textarea.
      // Ctrl+Enter igual: para Monaco es «insertar línea debajo»; aquí es el
      // autocompletar-desde-comentario de main.ts (vía onCtrlEnter).
      host.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && !e.shiftKey && e.key.toLowerCase() === 's') {
          e.preventDefault();
          e.stopPropagation();
          void this.saveCurrentFile();
          return;
        }
        if ((e.ctrlKey || e.metaKey) && !e.shiftKey && e.key === 'Enter') {
          e.preventDefault();
          e.stopPropagation();
          this.onCtrlEnter?.();
        }
      }, true);
      // La paleta de Monaco sigue a la cabina: ThemeManager reescribe las
      // vars de :root, así que basta observar `style` y redefinir el tema.
      this.themeObserver = new MutationObserver(() => applyBeatsTheme(m));
      this.themeObserver.observe(document.documentElement, { attributes: true, attributeFilter: ['style'] });
      host.style.display = 'block';
      plain.style.display = 'none';
      // Compatibilidad de sondas CDP: el input real de Monaco es su textarea
      // oculto — darle el id histórico mantiene realClick/realType válidos.
      // (0.5x: .ime-text-area; builds antiguos: .inputarea)
      const input = host.querySelector('textarea.ime-text-area, textarea.inputarea');
      if (input) {
        input.id = 'code-textarea';
        input.setAttribute('aria-label', 'Editor de código');
      }
      this.setValue(this.content);
      this.updateCursorStatus();
    } catch {
      this.monacoEd = null;
      notice('No se pudo montar Monaco; se usa el editor simple.', 'error');
    }
  }

  private render() {
    // El editor consume los mismos tokens que el resto de la cabina; antes
    // llevaba la paleta de VS Code escrita a fuego (#1e1e1e, #007acc) y
    // rompia la continuidad visual y cualquier cambio de tema.
    this.container.innerHTML = `
      <div class="monaco-editor-host col" style="width:100%;height:100%;background:var(--bg-main);color:var(--fg);font-family:var(--font-code);font-size:13px;position:relative">

        <div class="row" style="height:30px;flex:0 0 30px;padding:0 12px;justify-content:space-between;border-bottom:1px solid var(--border);font-size:11px">
          <div class="row" style="gap:8px">
            <span id="editor-file-title" class="muted" style="font-weight:500">Sin título</span>
            <span id="editor-dirty-flag" style="color:var(--warning);display:none">&#9679;</span>
          </div>
          <div class="row" style="gap:12px">
            <div class="row" id="editor-file-actions" role="group" aria-label="Acciones del archivo" style="gap:6px">${fileActionsMarkup()}</div>
            <span id="editor-lang" class="badge badge--accent">${escapeText(this.language)}</span>
            <span class="subtle">UTF-8</span>
          </div>
        </div>

        <div class="row grow" style="align-items:stretch;overflow:hidden;position:relative">
          <div id="editor-plain-surface" class="row grow" style="align-items:stretch;overflow:hidden">
          <div id="line-numbers" style="width:48px;flex:0 0 48px;border-right:1px solid var(--border);color:var(--fg-subtle);
               text-align:right;padding:10px 10px 10px 0;user-select:none;font-size:12px;line-height:1.55;
               font-family:var(--font-code);overflow:hidden">1</div>
          <!-- Resaltado por superposición: el <pre> pinta los colores y el
               <textarea> va encima con el texto TRANSPARENTE (solo se ve su
               cursor y su selección). Las dos capas comparten fuente, tamaño,
               interlineado, relleno y tab-size, que es lo que hace que las
               letras coincidan exactamente. Si se tocan esos valores, hay que
               tocarlos en las DOS o el texto se desalinea. -->
          <div class="grow" style="position:relative;display:flex;overflow:hidden">
            <div id="editor-find-bar" class="row" style="display:none;position:absolute;top:6px;right:14px;z-index:5;gap:4px;align-items:center;background:var(--bg-elevated,var(--bg-main));border:1px solid var(--border);border-radius:6px;padding:3px 6px;box-shadow:0 2px 8px rgba(0,0,0,.3)">
              <input class="input mono" id="editor-find-input" placeholder="Buscar en el archivo…" title="Buscar texto en el archivo (Enter: siguiente, Mayús+Enter: anterior, Esc: cerrar)" style="height:24px;font-size:12px;width:210px;padding:0 8px" />
              <span class="subtle mono" id="editor-find-count" style="font-size:11px;min-width:52px;text-align:center"></span>
              <button class="icon-btn" id="editor-find-prev" title="Coincidencia anterior">${icons.chevronUp(13)}</button>
              <button class="icon-btn" id="editor-find-next" title="Coincidencia siguiente">${icons.chevronDown(13)}</button>
              <button class="icon-btn" id="editor-find-close" title="Cerrar búsqueda">${icons.close(13)}</button>
            </div>
            <pre id="code-highlight" aria-hidden="true"
              style="position:absolute;inset:0;margin:0;pointer-events:none;overflow:hidden;
                     padding:10px 14px;font-family:var(--font-code);font-size:13px;line-height:1.55;tab-size:2;
                     white-space:pre;color:var(--fg)"></pre>
            <textarea id="code-textarea" aria-label="Editor de código" spellcheck="false"
              style="width:100%;height:100%;position:relative;background:transparent;color:transparent;
                     -webkit-text-fill-color:transparent;border:none;outline:none;resize:none;
                     padding:10px 14px;font-family:var(--font-code);font-size:13px;line-height:1.55;tab-size:2;
                     white-space:pre;overflow:auto;caret-color:var(--accent)"></textarea>
          </div>
          </div>
          <!-- Monaco real (ADR-B012) monta aquí cuando el vendor AMD carga;
               en ese caso editor-plain-surface queda oculto como fallback. -->
          <div id="editor-monaco-host" style="display:none;position:absolute;inset:0;z-index:2"></div>
          <!-- Archivo binario: tapa las dos superficies y no deja editar. -->
          <div id="editor-binary-notice" class="editor-binary" style="display:none">
            <div class="editor-binary__card">
              <div class="editor-binary__title">Archivo binario</div>
              <p id="editor-binary-name" class="mono"></p>
              <p>No es texto: DevAgents no lo muestra en el editor, porque guardarlo desde aquí lo corrompería.</p>
              <p class="subtle">Una base de datos, una imagen o un ejecutable se abren con su propia herramienta.</p>
            </div>
          </div>
        </div>

        <div class="row" style="height:24px;flex:0 0 24px;padding:0 12px;justify-content:space-between;
             border-top:1px solid var(--border);font-size:11px;color:var(--fg-subtle)">
          <span id="cursor-pos">Lín 1, Col 1</span>
          <span>Espacios: 2</span>
        </div>
      </div>
    `;

    this.lineNumbersElem = this.container.querySelector('#line-numbers')!;
    this.codeAreaElem = this.container.querySelector('#code-textarea')!;
    this.highlightElem = this.container.querySelector('#code-highlight')!;
    this.statusLineElem = this.container.querySelector('#cursor-pos')!;
    this.findBar = this.container.querySelector('#editor-find-bar')!;
    this.findInput = this.container.querySelector('#editor-find-input')!;
    this.findCount = this.container.querySelector('#editor-find-count')!;

    // Canvas/Diff nacen en gris; se ajustan a la ruta real (vacía o no).
    this.fileActionEls = fileActionButtons(this.container);
    syncFileActions(this.fileActionEls, this.filePath);
    this.container.querySelector('#editor-act-canvas')?.addEventListener('click', () => {
      if (this.filePath) this.onOpenCanvas?.();
    });
    this.container.querySelector('#editor-act-diff')?.addEventListener('click', () => {
      if (this.filePath) this.onReviewDiff?.();
    });

    this.bindEvents();
  }

  /** Capa de color bajo el textarea. */
  private highlightElem!: HTMLElement;
  private lang: Lang = 'text';

  /**
   * Repinta la capa de color y la mantiene alineada con el desplazamiento del
   * textarea. El salto final es deliberado: sin él, una última línea vacía no
   * reserva altura y el `<pre>` se desplaza respecto al textarea al llegar al
   * fondo del archivo.
   */
  private renderHighlight(): void {
    if (this.monacoEd || !this.highlightElem) return;
    this.highlightElem.innerHTML = highlight(this.content + '\n', this.lang);
    this.highlightElem.scrollTop = this.codeAreaElem.scrollTop;
    this.highlightElem.scrollLeft = this.codeAreaElem.scrollLeft;
  }

  private bindEvents() {
    this.codeAreaElem.addEventListener('input', () => {
      this.content = this.codeAreaElem.value;
      this.updateLineNumbers();
      this.renderHighlight();
      this.notifyChange();
    });

    this.codeAreaElem.addEventListener('scroll', () => {
      this.lineNumbersElem.scrollTop = this.codeAreaElem.scrollTop;
      this.highlightElem.scrollTop = this.codeAreaElem.scrollTop;
      this.highlightElem.scrollLeft = this.codeAreaElem.scrollLeft;
    });

    this.codeAreaElem.addEventListener('keyup', () => this.updateCursorStatus());
    this.codeAreaElem.addEventListener('click', () => this.updateCursorStatus());

    // Shortcuts: Ctrl+S (save file), Ctrl+F (buscar en el archivo)
    this.codeAreaElem.addEventListener('keydown', (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 's') {
        e.preventDefault();
        // Sin stopPropagation el evento sube al listener global de main.ts y
        // saveCurrentFile corre dos veces: con conflicto de disco se apilaban
        // dos confirmModal y el de abajo quedaba huérfano bloqueando la UI.
        e.stopPropagation();
        this.saveCurrentFile();
      }
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'f') {
        e.preventDefault();
        e.stopPropagation();
        this.openFindBar();
      }
      if (e.key === 'Tab') {
        e.preventDefault();
        // execCommand conserva la pila de undo nativa — con value= directo,
        // Ctrl+Z no deshacía nada de lo insertado por Tab.
        if (!document.execCommand('insertText', false, '  ')) {
          const start = this.codeAreaElem.selectionStart;
          const end = this.codeAreaElem.selectionEnd;
          this.codeAreaElem.value = this.codeAreaElem.value.substring(0, start) + '  ' + this.codeAreaElem.value.substring(end);
          this.codeAreaElem.selectionStart = this.codeAreaElem.selectionEnd = start + 2;
        }
        this.content = this.codeAreaElem.value;
        this.updateLineNumbers();
        this.notifyChange();
      }
    });

    // Barra de búsqueda en archivo (Ctrl+F). WebView2 no trae un buscador de
    // página nativo — sin esto el editor no tenía find.
    this.findInput.addEventListener('input', () => this.runFind(0));
    this.findInput.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') {
        e.preventDefault();
        this.runFind(e.shiftKey ? -1 : 1);
      }
      if (e.key === 'Escape') {
        e.preventDefault();
        this.closeFindBar();
      }
    });
    this.container.querySelector('#editor-find-next')!.addEventListener('click', () => this.runFind(1));
    this.container.querySelector('#editor-find-prev')!.addEventListener('click', () => this.runFind(-1));
    this.container.querySelector('#editor-find-close')!.addEventListener('click', () => this.closeFindBar());
  }

  private findBar!: HTMLElement;
  private findInput!: HTMLInputElement;
  private findCount!: HTMLElement;
  private findHits: number[] = [];
  private findIdx = -1;

  private openFindBar(): void {
    this.findBar.style.display = 'flex';
    // Si hay selección, es lo primero que se busca — igual que en VS Code.
    const sel = this.codeAreaElem.value.substring(this.codeAreaElem.selectionStart, this.codeAreaElem.selectionEnd);
    if (sel && sel.length < 120 && !sel.includes('\n')) this.findInput.value = sel;
    this.findInput.focus();
    this.findInput.select();
    this.runFind(0);
  }

  private closeFindBar(): void {
    this.findBar.style.display = 'none';
    this.findHits = [];
    this.findIdx = -1;
    this.findCount.textContent = '';
    this.codeAreaElem.focus();
  }

  /** dir 0 = recomputar sin mover; ±1 = siguiente/anterior coincidencia. */
  private runFind(dir: number): void {
    const needle = this.findInput.value;
    this.findHits = [];
    this.findIdx = -1;
    if (!needle) {
      this.findCount.textContent = '';
      return;
    }
    const hay = this.codeAreaElem.value.toLowerCase();
    const nd = needle.toLowerCase();
    let i = hay.indexOf(nd);
    while (i !== -1 && this.findHits.length < 5000) {
      this.findHits.push(i);
      i = hay.indexOf(nd, i + 1);
    }
    if (this.findHits.length === 0) {
      this.findCount.textContent = '0/0';
      return;
    }
    // Al seleccionar un hit, selectionStart queda en su inicio — por eso el
    // paso siguiente debe ser estricto (>/＜) o Enter re-elegiria el mismo.
    if (dir > 0) {
      const caret = this.codeAreaElem.selectionStart;
      this.findIdx = this.findHits.findIndex((h) => h > caret);
      if (this.findIdx === -1) this.findIdx = 0; // wrap
    } else if (dir < 0) {
      const caret = this.codeAreaElem.selectionStart;
      for (let k = this.findHits.length - 1; k >= 0; k--) {
        if (this.findHits[k] < caret) { this.findIdx = k; break; }
      }
      if (this.findIdx === -1) this.findIdx = this.findHits.length - 1; // wrap
    } else {
      const caret = this.codeAreaElem.selectionStart;
      this.findIdx = this.findHits.findIndex((h) => h >= caret);
      if (this.findIdx === -1) this.findIdx = 0;
    }
    const pos = this.findHits[this.findIdx];
    this.codeAreaElem.focus();
    this.codeAreaElem.setSelectionRange(pos, pos + needle.length);
    // scrollIntoView manual: la línea del acierto queda en el tercio superior.
    const lineNo = this.codeAreaElem.value.substring(0, pos).split('\n').length - 1;
    const lh = parseFloat(getComputedStyle(this.codeAreaElem).lineHeight) || 20;
    const target = lineNo * lh - this.codeAreaElem.clientHeight / 3;
    this.codeAreaElem.scrollTop = Math.max(0, target);
    this.codeAreaElem.dispatchEvent(new Event('scroll'));
    this.updateCursorStatus();
    this.findCount.textContent = `${this.findIdx + 1}/${this.findHits.length}`;
  }

  /**
   * Buffers vivos por ruta.
   *
   * Hay un único editor compartido entre todas las pestañas, así que cambiar de
   * pestaña volvía a leer el archivo del disco y se llevaba por delante lo que
   * hubieras escrito sin guardar. Aquí se conserva el texto de cada archivo
   * abierto: al volver a su pestaña se restaura tal y como lo dejaste.
   */
  private buffers = new Map<string, string>();

  /** Rutas cuyo buffer difiere de lo que hay en disco. */
  private dirtyPaths = new Set<string>();

  /**
   * H3 — dónde estabas mirando en cada pestaña.
   *
   * Conservar el TEXTO no basta. Con un archivo de mil líneas, volver a su
   * pestaña te dejaba arriba del todo y con el cursor en la posición 0: el
   * trabajo no se perdía, pero el sitio sí, y en un archivo largo eso cuesta
   * casi lo mismo. Se guarda la selección y el desplazamiento vertical.
   */
  private viewStates = new Map<string, { start: number; end: number; scroll: number } | any>();

  public isDirty(path: string): boolean {
    return this.dirtyPaths.has(path);
  }

  /** Guarda los borradores sin cambiar de pestaña ni descartar conflictos. */
  public saveAllFiles(): Promise<void> {
    if (this.splitOwner) return this.splitOwner.saveAllFiles();
    const save = (this.saveAllQueue ?? Promise.resolve()).then(() => this.saveDirtyBuffers());
    this.saveAllQueue = save;
    return save;
  }

  private async saveDirtyBuffers(): Promise<void> {
    if (this.filePath && this.dirtyPaths.has(this.filePath)) {
      this.buffers.set(this.filePath, this.content);
    }
    // Instantánea: el usuario puede seguir editando durante las escrituras.
    const pending = [...this.dirtyPaths].map(path => ({ path, content: this.buffers.get(path) }));
    for (const { path, content } of pending) {
      try {
        if (content === undefined) throw new Error('No se encuentra el borrador en memoria.');
        await this.bridge.send('doc.save', { path, content, force: false });
        // Una edición posterior a la instantánea sigue sucia y no se sobrescribe.
        this.markSaved(path, content);
      } catch (err) {
        notice(`No se pudo guardar ${path}: ${String(err)}. Se conservan los cambios sin guardar.`, 'error');
      }
    }
  }

  public async goToLine(): Promise<void> {
    if (!this.filePath) {
      notice('Abre un archivo para ir a una línea.', 'info');
      return;
    }
    const path = this.filePath;
    let count = this.monacoEd?.getModel()?.getLineCount() ?? this.content.split('\n').length;
    const input = await promptModal({ title: 'Ir a línea', label: `Número de línea (1–${count})`, placeholder: '1' });
    if (input === null) return;
    if (this.filePath !== path) {
      notice('El archivo activo cambió. Vuelve a elegir la línea en el archivo actual.', 'info');
      return;
    }
    count = this.monacoEd?.getModel()?.getLineCount() ?? this.content.split('\n').length;
    const line = Number(input.trim());
    if (!/^\d+$/.test(input.trim()) || !Number.isSafeInteger(line) || line < 1 || line > count) {
      notice(`Introduce un número entero de línea entre 1 y ${count}.`, 'error');
      return;
    }
    if (this.monacoEd) {
      this.monacoEd.setPosition({ lineNumber: line, column: 1 });
      this.monacoEd.revealLineInCenter(line);
      this.monacoEd.focus();
    } else {
      const offset = this.content.split('\n').slice(0, line - 1).reduce((n, text) => n + text.length + 1, 0);
      this.codeAreaElem.focus();
      this.codeAreaElem.setSelectionRange(offset, offset);
      const height = parseFloat(getComputedStyle(this.codeAreaElem).lineHeight) || 20;
      this.codeAreaElem.scrollTop = Math.max(0, (line - 1) * height - this.codeAreaElem.clientHeight / 2);
      this.codeAreaElem.dispatchEvent(new Event('scroll'));
    }
    this.updateCursorStatus();
  }

  public toggleWordWrap(): void {
    if (!this.monacoEd) {
      notice('El ajuste de línea requiere el editor Monaco.', 'info');
      return;
    }
    this.wordWrap = !this.wordWrap;
    this.monacoEd.updateOptions({ wordWrap: this.wordWrap ? 'on' : 'off' });
  }

  public toggleMinimap(): void {
    if (!this.monacoEd) {
      notice('El minimapa requiere el editor Monaco.', 'info');
      return;
    }
    const scrollTop = this.monacoEd.getScrollTop();
    const scrollLeft = this.monacoEd.getScrollLeft();
    this.minimapEnabled = !this.minimapEnabled;
    this.monacoEd.updateOptions({ minimap: { enabled: this.minimapEnabled } });
    this.monacoEd.setScrollPosition({ scrollTop, scrollLeft });
  }

  /** Dos vistas con cursores independientes y borradores compartidos por ruta. */
  public async split(direction: 'vertical' | 'horizontal'): Promise<void> {
    const owner = this.splitOwner ?? this;
    if (!this.filePath) { notice('Abre un archivo para dividir el editor.', 'info'); return; }
    const surface = owner.container.querySelector<HTMLElement>('.monaco-editor-host');
    if (!surface) return;
    owner.container.style.display = 'flex';
    owner.container.style.flexDirection = direction === 'vertical' ? 'row' : 'column';
    surface.style.flex = '1 1 0';
    surface.style.minWidth = surface.style.minHeight = '0';
    if (!owner.splitEditor) {
      const pane = document.createElement('div');
      pane.className = 'editor-split-pane';
      pane.style.cssText = 'flex:1 1 0;min-width:0;min-height:0;overflow:hidden;border:1px solid var(--border)';
      pane.setAttribute('aria-label', 'Editor dividido');
      owner.container.appendChild(pane);
      const child = new MonacoEditor(pane, this.bridge, { language: this.language });
      owner.splitEditor = child;
      child.splitOwner = owner;
      child.buffers = owner.buffers;
      child.dirtyPaths = owner.dirtyPaths;
      child.onChangeCallbacks = owner.onChangeCallbacks;
      child.onCtrlEnter = owner.onCtrlEnter;
      child.onOpenCanvas = owner.onOpenCanvas;
      child.onReviewDiff = owner.onReviewDiff;
      child.wordWrap = this.wordWrap;
      child.minimapEnabled = this.minimapEnabled;
      // Un archivo limpio también debe abrir con el texto de la vista actual.
      owner.buffers.set(this.filePath, this.content);
      child.setFilePath(this.filePath);
      child.setValue(this.content);
      await child.openFile(this.filePath);
      const close = document.createElement('button');
      close.className = 'btn btn--sm';
      close.textContent = 'Cerrar división';
      close.setAttribute('aria-label', 'Cerrar panel dividido');
      close.addEventListener('click', () => void owner.closeSplit());
      pane.querySelector('#editor-file-actions')?.appendChild(close);
    }
    owner.monacoEd?.layout();
    owner.splitEditor?.monacoEd?.layout();
  }

  public closeSplit(): void {
    const owner = this.splitOwner ?? this;
    const child = owner.splitEditor;
    if (!child) return;
    // No olvidar archivos: sus borradores siguen accesibles desde las pestañas.
    child.openRequest = (child.openRequest ?? 0) + 1;
    child.themeObserver?.disconnect();
    child.monacoEd?.dispose();
    child.monacoEd = null;
    child.container.remove();
    owner.splitEditor = null;
    owner.container.style.display = '';
    owner.container.style.flexDirection = '';
    const surface = owner.container.querySelector<HTMLElement>('.monaco-editor-host');
    if (surface) surface.style.flex = '';
    owner.monacoEd?.layout();
    owner.onFocus?.(owner);
    owner.monacoEd?.focus();
  }

  public async formatDocument(): Promise<void> {
    const action = this.filePath && !this.binaryPath && this.monacoEd?.getAction('editor.action.formatDocument');
    if (!action?.isSupported()) {
      notice('Sin formateador para este lenguaje.', 'info');
      return;
    }
    try {
      await action.run();
    } catch (error) {
      notice(`No se pudo formatear el documento: ${String(error)}`, 'error');
    }
  }

  /** Releer solo documentos limpios después de una escritura externa confirmada. */
  public async reloadSavedFile(path: string): Promise<void> {
    const owner = this.splitOwner ?? this;
    if (owner.isDirty(path)) return;
    owner.buffers.delete(path);
    for (const view of [owner, owner.splitEditor]) {
      if (view?.filePath === path) await view.openFile(path);
    }
  }

  /**
   * Olvida todo lo que se guardaba de un archivo: borrador, marca de
   * modificado y posición. La llama el cierre de pestaña.
   *
   * Sin esto el estado sobrevivía al cierre y reabrir el archivo devolvía el
   * borrador viejo en vez del contenido del disco.
   */
  public forgetFile(path: string): void {
    this.buffers.delete(path);
    this.dirtyPaths.delete(path);
    this.viewStates.delete(path);
    if (this.filePath === path) {
      this.setFilePath('');
      this.markDirty(false);
    }
    const peer = this.splitOwner ?? this.splitEditor;
    if (peer?.filePath === path) { peer.setFilePath(''); peer.setValue(''); peer.markDirty(false); }
  }

  /** Anota dónde está el cursor y la vista del archivo abierto ahora mismo. */
  private captureViewState(): void {
    if (!this.filePath) return;
    if (this.monacoEd) {
      this.viewStates.set(this.filePath, this.monacoEd.saveViewState());
      return;
    }
    if (!this.codeAreaElem) return;
    this.viewStates.set(this.filePath, {
      start: this.codeAreaElem.selectionStart,
      end: this.codeAreaElem.selectionEnd,
      scroll: this.codeAreaElem.scrollTop,
    });
  }

  /**
   * Devuelve el cursor y la vista a donde estaban.
   *
   * El desplazamiento se aplica DESPUÉS del pintado (`requestAnimationFrame`):
   * asignar `scrollTop` sobre un textarea cuyo contenido acaba de cambiar se
   * pierde, porque el navegador aún no ha calculado la altura del texto nuevo
   * y recorta el valor a lo que cabe en ese instante.
   */
  private restoreViewState(path: string): void {
    const st = this.viewStates.get(path);
    if (this.monacoEd) {
      if (st) this.monacoEd.restoreViewState(st);
      else this.monacoEd.setPosition({ lineNumber: 1, column: 1 });
      this.updateCursorStatus();
      return;
    }
    if (!this.codeAreaElem) return;
    if (!st) {
      // Archivo que se abre por primera vez. Asignar `value` deja el cursor al
      // FINAL del texto, así que un archivo de 5.000 líneas se abría por el
      // final en cuanto recibía el foco. Lo natural es empezar por arriba.
      // Salió al probar el restaurado por pestaña: el caso «sin estado
      // guardado» era el que nadie miraba.
      try {
        this.codeAreaElem.setSelectionRange(0, 0);
      } catch {
        // Un textarea aún sin montar no acepta selección.
      }
      this.codeAreaElem.scrollTop = 0;
      this.updateCursorStatus();
      return;
    }
    const max = this.content.length;
    const start = Math.min(st.start, max);
    const end = Math.min(st.end, max);
    try {
      this.codeAreaElem.setSelectionRange(start, end);
    } catch {
      // Un textarea aún sin montar no acepta selección; no es motivo para
      // tumbar la apertura del archivo.
    }
    const apply = () => {
      this.codeAreaElem.scrollTop = st.scroll;
      if (this.highlightElem) this.highlightElem.scrollTop = st.scroll;
      if (this.lineNumbersElem) this.lineNumbersElem.scrollTop = st.scroll;
    };
    if (typeof requestAnimationFrame === 'function') requestAnimationFrame(apply);
    else apply();
    this.updateCursorStatus();
  }

  public async openFile(path: string): Promise<void> {
    const request = this.openRequest = (this.openRequest ?? 0) + 1;
    // Antes de irse, guardar en memoria lo que hubiera en el editor: el texto
    // y también DÓNDE estabas dentro de él.
    if (this.filePath && this.filePath !== path) {
      this.buffers.set(this.filePath, this.content);
      this.captureViewState();
    }

    this.setFilePath(path);
    const titleElem = this.container.querySelector('#editor-file-title');
    if (titleElem) {
      const parts = path.split(/[\/\\]/);
      titleElem.textContent = parts[parts.length - 1] || path;
    }

      // The fallback grammar is deliberately smaller. Monaco and its visible
      // language badge share the full extension map, including HTML and JS.
      this.lang = langFor(path);
      this.language = monacoLanguageFor(path);
    this.mostrarAvisoBinario(null);

    const langElem = this.container.querySelector('#editor-lang');
      if (langElem) langElem.textContent = (this.language === 'cpp' ? 'c++' : this.language === 'plaintext' ? 'text' : this.language).toUpperCase();
    if (this.monacoEd) {
      const model = this.monacoEd.getModel();
      if (model) {
          (window as any).monaco?.editor.setModelLanguage(model, this.language);
        // setModelLanguage repone las opciones del modelo desde los defaults
        // del lenguaje — hay que volver a apagar la colorización de parejas.
        model.updateOptions({ bracketColorizationOptions: { enabled: false } });
      }
    }

    // Si ya se había abierto y quedó sin guardar, gana el buffer en memoria: ir
    // a otra pestaña y volver no debe perder trabajo.
    const pending = this.buffers.get(path);
    if (pending !== undefined && this.dirtyPaths.has(path)) {
      this.setValue(pending);
      this.markDirty(true);
      this.restoreViewState(path);
      return;
    }

    try {
      const res = await this.bridge.send<{ path: string }, { payload?: { content: string }; content?: string }>('doc.open', { path });
      if (request !== this.openRequest) return;
      // Otra vista pudo editar el mismo archivo mientras llegaba el disco.
      const latest = this.buffers.get(path);
      if (latest !== undefined && this.dirtyPaths.has(path)) {
        this.setValue(latest);
        this.markDirty(true);
        this.restoreViewState(path);
        return;
      }
      const text = res?.payload?.content ?? res?.content;
      if (typeof text === 'string' && pareceBinario(text)) {
        this.setValue('');
        this.buffers.delete(path);
        this.dirtyPaths.delete(path);
        this.markDirty(false);
        this.mostrarAvisoBinario(path);
        return;
      }
      if (typeof text === 'string') {
        this.setValue(text);
        this.buffers.set(path, text);
        this.dirtyPaths.delete(path);
        this.markDirty(false);
        this.restoreViewState(path);
        return;
      }
      // Respuesta sin contenido: se trata igual que un fallo. Devolver algo que
      // no es una cadena y seguir como si nada dejaba el editor mostrando el
      // archivo ANTERIOR bajo el título del nuevo.
      throw new Error('El motor no devolvió el contenido del archivo');
    } catch (err) {
      if (request !== this.openRequest) return;
      // Un archivo que ya no existe (borrado fuera de la aplicación, o movido)
      // caía aquí y solo dejaba un console.warn: el editor se quedaba con el
      // contenido del archivo anterior y, para el usuario, pulsar la pestaña
      // sencillamente NO HACÍA NADA. Encontrado por el usuario con una pestaña
      // cuyo archivo se habia borrado por detras.
      //
      // Ahora el estado se ve: el editor queda vacío y explica qué pasó.
      this.setValue(
        `// No se pudo abrir este archivo.\n` +
          `//\n` +
          `//   ${path}\n` +
          `//\n` +
          `// Puede que se haya borrado, movido o renombrado fuera de DevAgents.\n` +
          `// Cierra la pestaña con la X, o vuelve a crearlo desde el explorador\n` +
          `// (clic derecho sobre su carpeta).\n` +
          `//\n` +
          `// Detalle: ${String(err)}\n`
      );
      this.buffers.delete(path);
      this.dirtyPaths.delete(path);
      this.viewStates.delete(path);
      this.markDirty(false);
      notice(`No se pudo abrir ${path.split(/[\\/]/).pop()}: el archivo ya no existe.`, 'error');
    }
  }

  /** Refleja en la barra del editor si el archivo actual tiene cambios. */
  private markDirty(dirty: boolean): void {
    if (this.filePath) {
      if (dirty) this.dirtyPaths.add(this.filePath);
      else this.dirtyPaths.delete(this.filePath);
    }
    const flag = this.container.querySelector('#editor-dirty-flag') as HTMLElement | null;
    if (flag) flag.style.display = dirty ? '' : 'none';
    const peer = this.splitOwner ?? this.splitEditor;
    if (peer && this.filePath && peer.filePath === this.filePath) {
      const peerFlag = peer.container.querySelector<HTMLElement>('#editor-dirty-flag');
      if (peerFlag) peerFlag.style.display = dirty ? '' : 'none';
    }
  }

  private markSaved(path: string, content: string): void {
    if (this.buffers.get(path) !== content) return;
    this.dirtyPaths.delete(path);
    const owner = this.splitOwner ?? this;
    for (const view of [owner, owner.splitEditor]) {
      if (view?.filePath === path && view.content === content) view.markDirty(false);
    }
  }

  /**
   * Muestra (con una ruta) u oculta (con null) el aviso de archivo binario, y
   * pone el editor en solo lectura mientras está a la vista.
   */
  private mostrarAvisoBinario(path: string | null): void {
    this.binaryPath = path;
    const aviso = this.container.querySelector<HTMLElement>('#editor-binary-notice');
    if (aviso) aviso.style.display = path ? 'flex' : 'none';
    const nombre = this.container.querySelector<HTMLElement>('#editor-binary-name');
    if (nombre) nombre.textContent = path ? path.split(/[\\/]/).pop() || path : '';
    const langElem = this.container.querySelector('#editor-lang');
    if (langElem && path) langElem.textContent = 'BINARIO';
    this.codeAreaElem.readOnly = !!path;
    this.monacoEd?.updateOptions({ readOnly: !!path });
  }

  /** Ruta del binario a la vista; null si lo que hay es texto. */
  private binaryPath: string | null = null;

  /** La ruta externa solo se autoriza por selección nativa y token de un uso. */
  public async saveCurrentFileAs(): Promise<void> {
    if (!this.filePath || this.binaryPath === this.filePath) return;
    const originalPath = this.filePath;
    const content = this.content;
    try {
      const response = await this.bridge.send<{}, { payload?: { cancelled: boolean; path?: string; saveToken?: string } }>(
        'dialog.saveAs', {}, 300_000);
      const choice = response.payload;
      if (choice?.cancelled) return;
      if (!choice?.path || !choice.saveToken) throw new Error('El diálogo no autorizó una ruta de guardado.');
      // El diálogo nativo ya confirma sobrescritura. El token no se conserva
      // ni se reutiliza en reintentos, aunque falle la escritura.
      await this.bridge.send('doc.save', { path: choice.path, content, force: true, saveToken: choice.saveToken });
      if (choice.path === originalPath && this.filePath === originalPath && this.content === content) {
        this.buffers.set(originalPath, content);
        this.markDirty(false);
      } else {
        // Conservar el borrador original; la copia guardada abre su pestaña.
        document.dispatchEvent(new CustomEvent('devagents:open-file', { detail: choice.path }));
      }
      notice(`Guardado: ${choice.path.split(/[\\/]/).pop()}`, 'ok');
    } catch (err) {
      notice(`No se pudo guardar como: ${String(err)}`, 'error');
    }
  }

  public async saveCurrentFile(): Promise<void> {
    if (!this.filePath) return;
    // Un binario no se guarda nunca desde el editor: lo que hay en memoria no
    // son sus bytes, y escribirlo lo corrompería.
    if (this.binaryPath === this.filePath) return;
    const path = this.filePath;
    const content = this.content;
    // Se guarda SIN force primero: el motor compara el mtime del disco con el
    // de la última lectura y rechaza si el archivo cambió por fuera (otro
    // editor, un agente, git checkout...). Antes se mandaba force:true siempre
    // y esa detección era código muerto — un guardado pisaba cambios ajenos
    // sin avisar.
    try {
      await this.bridge.send<{ path: string; content: string; force: boolean }, { payload?: { saved: boolean } }>('doc.save', {
        path,
        content,
        force: false,
      });
      // Guardado: el buffer pasa a coincidir con el disco.
      this.markSaved(path, content);
    } catch (err) {
      if (String(err).includes('E_SAVE_NOT_AUTHORIZED')) {
        if (this.filePath === path && this.content === content) await this.saveCurrentFileAs();
        else notice('El archivo cambió durante el guardado; se conservan los cambios sin guardar.', 'info');
        return;
      }
      if (String(err).includes('E_SAVE_CONFLICT')) {
        // El archivo cambió en disco desde que se abrió. Decisión del usuario:
        // sobrescribir con su versión, o quedarse con la del disco.
        const name = path.split(/[\\/]/).pop() || path;
        const overwrite = await confirmModal({
          title: `${name} cambió en disco`,
          paragraphs: [
            'El archivo cambió en disco desde que lo abriste.',
            'Sobrescribir guarda tu versión encima de la del disco. Recargar vuelve ' +
              'al contenido del disco y pierde tus cambios sin deshacer.',
          ],
          confirmLabel: 'Sobrescribir el disco',
          cancelLabel: 'Recargar del disco',
          danger: true,
        });
        if (this.filePath !== path || this.content !== content) {
          notice('El archivo cambió durante la confirmación; se conservan los cambios sin guardar.', 'info');
          return;
        }
        if (overwrite) {
          await this.bridge.send('doc.save', {
            path,
            content,
            force: true,
          });
          this.markSaved(path, content);
          return;
        }
        // Recargar desde disco: se olvida el buffer y se reabre.
        // OJO: forgetFile limpia filePath si coincide — capturar antes.
        this.forgetFile(path);
        await this.openFile(path);
        return;
      }
      console.error('Error al guardar documento:', err);
      notice(`No se pudo guardar ${path.split(/[\\/]/).pop()}: ${String(err)}`, 'error');
    }
  }

  public setValue(text: string) {
    this.content = text;
    if (this.monacoEd) {
      this.settingValue = true;
      try {
        if (this.monacoEd.getValue() !== text) this.monacoEd.setValue(text);
      } finally {
        this.settingValue = false;
      }
      this.updateCursorStatus();
      return;
    }
    this.codeAreaElem.value = text;
    this.updateLineNumbers();
    this.renderHighlight();
    this.updateCursorStatus();
  }

  /** Ruta del archivo abierto, o cadena vacía si no hay ninguno. */
  public getFilePath(): string {
    return this.filePath;
  }

  public getValue(): string {
    return this.content;
  }

  public onChange(cb: (text: string) => void) {
    this.onChangeCallbacks.push(cb);
  }

  private notifyChange() {
    // Se anota tambien en `buffers`/`dirtyPaths`: es lo que permite volver a
    // esta pestaña más tarde y encontrar el texto como lo dejaste.
    if (this.filePath) this.buffers.set(this.filePath, this.content);
    this.markDirty(true);
    const peer = this.splitOwner ?? this.splitEditor;
    if (peer && this.filePath && peer.filePath === this.filePath) {
      const position = peer.monacoEd?.saveViewState();
      peer.setValue(this.content);
      if (position) peer.monacoEd?.restoreViewState(position);
      peer.markDirty(true);
    }
    for (const cb of this.onChangeCallbacks) {
      cb(this.content);
    }
  }

  private updateLineNumbers() {
    if (this.monacoEd) return;
    const lineCount = (this.content.match(/\n/g) || []).length + 1;
    let linesHtml = '';
    for (let i = 1; i <= lineCount; i++) {
      linesHtml += `<div>${i}</div>`;
    }
    this.lineNumbersElem.innerHTML = linesHtml;
  }

  private updateCursorStatus() {
    if (this.monacoEd) {
      const p = this.monacoEd.getPosition();
      if (p) this.statusLineElem.textContent = `Lín ${p.lineNumber}, Col ${p.column}`;
      return;
    }
    const pos = this.codeAreaElem.selectionStart;
    const textBefore = this.codeAreaElem.value.substring(0, pos);
    const lines = textBefore.split('\n');
    const currentLine = lines.length;
    const currentCol = lines[lines.length - 1].length + 1;
    this.statusLineElem.textContent = `Lín ${currentLine}, Col ${currentCol}`;
  }
}
