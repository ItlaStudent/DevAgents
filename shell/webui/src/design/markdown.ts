import { escapeText as escapeHtml } from './html';
import { highlight, langFromFence } from '../editor/highlight';
/**
 * Renderizador de Markdown mínimo para las respuestas del agente.
 *
 * Por qué uno propio y no una librería: la CSP de la cabina prohíbe contenido
 * remoto, así que cualquier dependencia habría que vendorizarla dentro del
 * bundle, y para lo que escribe un modelo — encabezados, negrita, listas,
 * bloques de código y alguna tabla — no compensa el peso.
 *
 * SEGURIDAD: se analizan delimitadores Markdown como texto y se escapa cada
 * hoja antes de emitir HTML. Solo el renderizador produce etiquetas; el modelo
 * nunca puede introducir markup, atributos o URLs ejecutables.
 */



/** Aplica los formatos de una sola línea (negrita, cursiva, código, tachado). */
function inline(s: string): string {
  return escapeHtml(s)
    .replace(/&#96;((?:(?!&#96;).)+)&#96;/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*\n]+)\*/g, '$1<em>$2</em>')
    .replace(/~~([^~]+)~~/g, '<del>$1</del>');
}

/**
 * E2.6 — «Ejecutar esto»: un bloque que es claramente un comando lleva su
 * botón. Ask → Agent: la respuesta del planificador en modo chat suele traer
 * el comando que resuelve lo preguntado; antes había que copiarlo a mano a la
 * terminal.
 *
 * Se marca por lenguaje de la valla (```bash, ```cmd…) y, si no trae, por
 * pinta de la primera línea (empieza por un ejecutable común). Un bloque de
 * código fuente (js, py, zig) NO es ejecutable como shell y no lleva botón.
 */
const SHELL_LANGS = new Set(['bash', 'sh', 'shell', 'zsh', 'cmd', 'bat', 'batch', 'powershell', 'ps1', 'console', 'terminal', 'dos']);
const CMD_HINT = /^\s*(cd|dir|copy|xcopy|move|del|erase|type|echo|set|call|start|ren|md|mkdir|rd|rmdir|node|npm|npx|yarn|pnpm|bun|deno|git|zig|python|py|pip|pip3|uv|cargo|rustc|go|java|javac|curl|wget|docker|kubectl|make|cmake|gcc|clang|cl|link|msbuild|dotnet|php|ruby|perl|sqlite3|ffmpeg|tar|expand|certutil|powershell|pwsh|where|find|findstr|grep|sed|awk|chmod|chown|sudo|apt|brew|\.\.?[\/\\]|[a-zA-Z]:[\/\\])/i;

function looksLikeCommand(lang: string, code: string): boolean {
  const l = lang.trim().toLowerCase();
  if (l && SHELL_LANGS.has(l)) return true;
  // Lenguaje de programación declarado: no es un comando de shell.
  if (l && !SHELL_LANGS.has(l) && l !== 'text' && l !== 'txt' && l !== 'plaintext') return false;
  const first = code.split('\n').find((s) => s.trim() !== '') ?? '';
  return CMD_HINT.test(first);
}

function renderTable(rows: string[]): string {
  const cells = (line: string): string[] =>
    line
      .replace(/^\s*\|/, '')
      .replace(/\|\s*$/, '')
      .split('|')
      .map((c) => c.trim());
  const head = cells(rows[0]);
  // La segunda fila de una tabla markdown es el separador (|---|---|): se salta.
  const body = rows.slice(2).map(cells);
  const th = head.map((c) => `<th>${inline(c)}</th>`).join('');
  const tr = body.map((r) => `<tr>${r.map((c) => `<td>${inline(c)}</td>`).join('')}</tr>`).join('');
  return `<table><thead><tr>${th}</tr></thead><tbody>${tr}</tbody></table>`;
}

/** Devuelve HTML listo para `innerHTML`. La entrada se escapa por dentro. */
export function renderMarkdown(raw: string): string {
  // Analizar delimitadores antes de escapar conserva las vallas/backticks.
  // Cada hoja se escapa al emitirse; el texto nunca se trata como markup.
  const lines = (raw ?? '').split('\n');
  const out: string[] = [];

  let i = 0;
  let listOpen: 'ul' | 'ol' | null = null;
  const closeList = (): void => {
    if (listOpen) {
      out.push(`</${listOpen}>`);
      listOpen = null;
    }
  };

  while (i < lines.length) {
    const line = lines[i];

    // Bloque de código con vallas. Se consume entero sin tocar su contenido:
    // dentro de un ```bloque``` el markdown no se interpreta.
    const fence = line.match(/^\s*```(\w*)\s*$/);
    if (fence) {
      closeList();
      const buf: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i])) {
        buf.push(lines[i]);
        i++;
      }
      i++; // saltar la valla de cierre
      const code = buf.join('\n');
      const runBtn = looksLikeCommand(fence[1], code)
        ? '<button type="button" class="md-cmd__run" title="Ejecutar este bloque en la terminal integrada">Ejecutar esto</button>'
        : '';
      // «Copiar» en TODO bloque; el texto sale del <code> al pulsar
      // (ver code_copy.ts), así que aquí solo hay marcado fijo, sin datos.
      const copyBtn =
        '<button type="button" class="md-copy" aria-label="Copiar código" title="Copiar código">Copiar</button>';
      out.push(`<pre class="md-pre"><span class="md-pre__tools">${runBtn}${copyBtn}</span><code>${highlight(code, langFromFence(fence[1]))}</code></pre>`);
      continue;
    }

    // Tabla: se agrupan las filas consecutivas que empiezan por |.
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
      closeList();
      const rows: string[] = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) {
        rows.push(lines[i]);
        i++;
      }
      out.push(renderTable(rows));
      continue;
    }

    const heading = line.match(/^\s*(#{1,3})\s+(.*)$/);
    if (heading) {
      closeList();
      const level = heading[1].length;
      out.push(`<h${level}>${inline(heading[2])}</h${level}>`);
      i++;
      continue;
    }

    const quote = line.match(/^\s*>\s?(.*)$/);
    if (quote) {
      closeList();
      out.push(`<blockquote>${inline(quote[1])}</blockquote>`);
      i++;
      continue;
    }

    const ul = line.match(/^\s*[-*+]\s+(.*)$/);
    const ol = line.match(/^\s*\d+[.)]\s+(.*)$/);
    if (ul || ol) {
      const want: 'ul' | 'ol' = ul ? 'ul' : 'ol';
      if (listOpen !== want) {
        closeList();
        out.push(`<${want}>`);
        listOpen = want;
      }
      out.push(`<li>${inline((ul ? ul[1] : ol![1]))}</li>`);
      i++;
      continue;
    }

    if (/^\s*(-{3,}|\*{3,})\s*$/.test(line)) {
      closeList();
      out.push('<hr/>');
      i++;
      continue;
    }

    if (line.trim() === '') {
      closeList();
      i++;
      continue;
    }

    // Párrafo: se juntan las líneas seguidas para que un salto suelto no parta
    // la frase, que es como se comporta markdown de verdad.
    closeList();
    const para: string[] = [];
    while (
      i < lines.length &&
      lines[i].trim() !== '' &&
      !/^\s*(#{1,3}\s|[-*+]\s|\d+[.)]\s|```|\||>)/.test(lines[i])
    ) {
      para.push(lines[i].trim());
      i++;
    }
    // Un delimitador suelto no es un bloque; consumirlo evita un bucle infinito.
    if (!para.length) para.push(lines[i++].trim());
    out.push(`<p>${inline(para.join(' '))}</p>`);
  }

  closeList();
  return out.join('');
}
