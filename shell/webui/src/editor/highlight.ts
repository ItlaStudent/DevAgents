import { escapeText as esc } from '../design/html';
/**
 * Resaltado de sintaxis propio, sin dependencias.
 *
 * Se descartó vendorizar CodeMirror o Monaco: la CSP de la cabina prohíbe
 * contenido remoto, así que habría que empaquetar la librería entera dentro del
 * bundle para conseguir colores. Esto son ~120 líneas y cubre lo que el
 * proyecto produce y lee de verdad.
 *
 * Cómo funciona: se tokeniza por líneas con una única expresión regular por
 * lenguaje y se emite HTML con clases. El resultado va en un `<pre>` DEBAJO de
 * un `<textarea>` de texto transparente; ambos comparten fuente, tamaño,
 * interlineado y relleno, así que las letras coinciden píxel a píxel y el
 * cursor real sigue siendo el del textarea. Es la técnica clásica de "overlay",
 * y es la única que conserva sin trampas el comportamiento nativo de edición,
 * selección, deshacer y accesibilidad.
 */

export type Lang = 'python' | 'zig' | 'typescript' | 'cpp' | 'json' | 'markdown' | 'bash' | 'powershell' | 'text';

/** Deduce el lenguaje por extensión. `text` desactiva el resaltado. */
export function langFor(path: string): Lang {
  const p = path.toLowerCase();
  if (p.endsWith('.py')) return 'python';
  if (p.endsWith('.zig')) return 'zig';
  if (p.endsWith('.ts') || p.endsWith('.tsx') || p.endsWith('.js') || p.endsWith('.mjs')) return 'typescript';
  if (p.endsWith('.c') || p.endsWith('.h') || p.endsWith('.cpp') || p.endsWith('.hpp') || p.endsWith('.cc'))
    return 'cpp';
  if (p.endsWith('.json')) return 'json';
  if (p.endsWith('.md')) return 'markdown';
  return 'text';
}

/**
 * — etiqueta de la valla de un bloque de código del chat (```ts,
 * ```py…) a un lenguaje de este resaltador. Una etiqueta desconocida o
 * ausente queda como `text`, es decir, texto plano escapado.
 */
const FENCE_ALIASES: Record<string, Lang> = {
  ts: 'typescript', tsx: 'typescript', typescript: 'typescript',
  js: 'typescript', jsx: 'typescript', javascript: 'typescript', mjs: 'typescript', cjs: 'typescript',
  py: 'python', python: 'python',
  zig: 'zig',
  c: 'cpp', h: 'cpp', cpp: 'cpp', hpp: 'cpp', cc: 'cpp', cxx: 'cpp',
  json: 'json',
  md: 'markdown', markdown: 'markdown',
  bash: 'bash', sh: 'bash',
  powershell: 'powershell', ps1: 'powershell',
};

export function langFromFence(tag: string): Lang {
  const key = (tag ?? '').trim().toLowerCase();
  return Object.prototype.hasOwnProperty.call(FENCE_ALIASES, key) ? FENCE_ALIASES[key] : 'text';
}

const KEYWORDS: Record<Exclude<Lang, 'json' | 'markdown' | 'text'>, string[]> = {
  python: ['def','class','return','if','elif','else','for','while','in','not','and','or','import','from','as','with','try','except','finally','raise','lambda','None','True','False','self','pass','break','continue','yield','global','nonlocal','assert','del','is','async','await'],
  zig: ['const','var','fn','pub','return','if','else','while','for','switch','struct','enum','union','error','try','catch','defer','errdefer','comptime','inline','export','extern','test','and','or','orelse','unreachable','null','true','false','usingnamespace','anytype','align','break','continue'],
  typescript: ['const','let','var','function','return','if','else','for','while','switch','case','break','continue','class','extends','implements','interface','type','enum','import','from','export','default','new','this','super','try','catch','finally','throw','async','await','yield','typeof','instanceof','in','of','void','null','undefined','true','false','public','private','protected','readonly','static','as','satisfies'],
  cpp: ['int','char','bool','void','float','double','long','short','unsigned','signed','const','static','struct','class','public','private','protected','virtual','override','return','if','else','for','while','switch','case','break','continue','new','delete','this','try','catch','throw','namespace','using','template','typename','auto','nullptr','true','false','sizeof','constexpr','inline','explicit','operator','friend','enum','union','extern'],
  bash: ['if','then','elif','else','fi','for','while','until','do','done','in','case','esac','function','select','time','coproc','return','break','continue','export','local','readonly','declare','unset'],
  powershell: ['if','elseif','else','switch','for','foreach','while','do','until','in','function','filter','return','break','continue','try','catch','finally','throw','trap','param','begin','process','end','class','enum','using','exit'],
};

/** Comentario de línea por lenguaje. */
const LINE_COMMENT: Partial<Record<Lang, string>> = {
  python: '#',
  zig: '//',
  typescript: '//',
  cpp: '//',
};



/**
 * Devuelve el HTML resaltado del texto completo.
 *
 * Importante: NO se altera ni un carácter del contenido — misma longitud de
 * líneas y mismos saltos —, porque el `<pre>` tiene que alinearse exactamente
 * con el textarea que lleva encima.
 */
export function highlight(code: string, lang: Lang): string {
  if (lang === 'text') return esc(code);
  if (lang === 'markdown') return highlightMarkdown(code);
  if (lang === 'json') return highlightJson(code);
  if (lang === 'bash' || lang === 'powershell') return highlightShell(code, lang);

  const kw = new Set(KEYWORDS[lang]);
  const comment = LINE_COMMENT[lang] || '//';
  const out: string[] = [];

  for (const line of code.split('\n')) {
    // El comentario gana sobre todo lo demás a partir de donde empieza, salvo
    // que caiga dentro de una cadena; se comprueba contando comillas previas.
    const idx = commentStart(line, comment);
    const codePart = idx >= 0 ? line.slice(0, idx) : line;
    const commentPart = idx >= 0 ? line.slice(idx) : '';

    let html = '';
    // Cadenas primero: dentro de una cadena no hay palabras clave ni números.
    const re = /("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')/g;
    let last = 0;
    let m: RegExpExecArray | null;
    while ((m = re.exec(codePart)) !== null) {
      html += highlightWords(codePart.slice(last, m.index), kw);
      html += `<span class="tok-str">${esc(m[0])}</span>`;
      last = m.index + m[0].length;
    }
    html += highlightWords(codePart.slice(last), kw);
    if (commentPart) html += `<span class="tok-com">${esc(commentPart)}</span>`;
    out.push(html);
  }
  return out.join('\n');
}

/** Posición del comentario, ignorando el que aparezca dentro de una cadena. */
function commentStart(line: string, marker: string): number {
  let inStr: string | null = null;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (inStr) {
      if (c === '\\') i++;
      else if (c === inStr) inStr = null;
      continue;
    }
    if (c === '"' || c === "'") {
      inStr = c;
      continue;
    }
    if (line.startsWith(marker, i)) return i;
  }
  return -1;
}

function highlightWords(chunk: string, kw: Set<string>): string {
  // Tokenizar la fuente, no sus entidades: resaltar «39» dentro de &#39;
  // rompería el escape y también la alineación con el textarea.
  const re = /\b([A-Za-z_][A-Za-z0-9_]*)\b|\b(\d[\d_.xXa-fA-F]*)\b/g;
  let out = '';
  let last = 0;
  for (const match of chunk.matchAll(re)) {
    out += esc(chunk.slice(last, match.index));
    const text = esc(match[0]);
    out += match[2] ? `<span class="tok-num">${text}</span>`
      : kw.has(match[1]) ? `<span class="tok-kw">${text}</span>` : text;
    last = match.index! + match[0].length;
  }
  return out + esc(chunk.slice(last));
}

/** Fuente sin escapar al tokenizar; cada fragmento se escapa antes de emitir HTML. */
function highlightShell(code: string, lang: 'bash' | 'powershell'): string {
  const powershell = lang === 'powershell';
  const kw = new Set(KEYWORDS[lang]);
  // Las cadenas y los escapes consumen sus # antes de buscar comentarios.
  // PowerShell escapa con ` y duplica las comillas en cadenas literales.
  const re = powershell
    ? /<#[\s\S]*?#>|#[^\n]*|"(?:[^"`]|`[\s\S])*"|'(?:[^']|'')*'|`[\s\S]|\$(?:\{[^}\r\n]+\}|(?:[A-Za-z_]\w*:)?[A-Za-z_]\w*|[0-9?^$])|\b[A-Za-z]+-[A-Za-z][A-Za-z0-9]*\b|\b[A-Za-z_]\w*\b|\b\d[\d_.]*\b/g
    : /#[^\n]*|"(?:[^"\\]|\\[\s\S])*"|'[^']*'|\\[\s\S]|\$(?:\{[^}\r\n]+\}|[A-Za-z_]\w*|[0-9@*#?$!-])|\b[A-Za-z_]\w*\b|\b\d[\d_.]*\b/g;
  let out = '';
  let last = 0;
  for (const match of code.matchAll(re)) {
    out += esc(code.slice(last, match.index));
    const token = match[0];
    const cls = token.startsWith('#') || (powershell && token.startsWith('<#')) ? 'tok-com'
      : token.startsWith('"') || token.startsWith("'") ? 'tok-str'
      : token.startsWith('$') ? 'tok-key'
      : /^\d/.test(token) ? 'tok-num'
      : kw.has(powershell ? token.toLowerCase() : token) || (powershell && /^[A-Za-z]+-[A-Za-z][A-Za-z0-9]*$/.test(token)) ? 'tok-kw' : '';
    out += cls ? `<span class="${cls}">${esc(token)}</span>` : esc(token);
    last = match.index! + token.length;
  }
  return out + esc(code.slice(last));
}

function highlightJson(code: string): string {
  const re = /"(?:[^"\\]|\\.)*"|\b(?:true|false|null)\b|-?\b\d+(?:\.\d+)?/g;
  let out = '';
  let last = 0;
  for (const match of code.matchAll(re)) {
    out += esc(code.slice(last, match.index));
    const cls = match[0].startsWith('"')
      ? /^\s*:/.test(code.slice(match.index! + match[0].length)) ? 'tok-key' : 'tok-str'
      : /^(true|false|null)$/.test(match[0]) ? 'tok-kw' : 'tok-num';
    out += `<span class="${cls}">${esc(match[0])}</span>`;
    last = match.index! + match[0].length;
  }
  return out + esc(code.slice(last));
}

function highlightMarkdown(code: string): string {
  return code
    .split('\n')
    .map((line) => {
      if (/^\s*#{1,6}\s/.test(line)) return `<span class="tok-kw">${esc(line)}</span>`;
      if (/^\s*([-*+]|\d+\.)\s/.test(line)) {
        const m = line.match(/^(\s*(?:[-*+]|\d+\.)\s)(.*)$/);
        if (m) return `<span class="tok-num">${esc(m[1])}</span>${esc(m[2])}`;
      }
      if (/^\s*>/.test(line)) return `<span class="tok-com">${esc(line)}</span>`;
      if (/^\s*```/.test(line)) return `<span class="tok-str">${esc(line)}</span>`;
      return esc(line);
    })
    .join('\n');
}
