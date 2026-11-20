import { OrderEvent, eventPayload } from './bridge/core_api';

export interface ArtifactAction {
  /** Página HTML comprobada que presenta un script de navegador. */
  page?: string;
  /** Intérprete permitido para el artefacto; null significa no ejecutar. */
  runner: string | null;
}

/** Intérprete de extensiones cuyo runtime no es ambiguo. */
export function runnerFor(name: string): string | null {
  const n = name.toLowerCase();
  if (n.endsWith('.py')) return 'python';
  if (n.endsWith('.js') || n.endsWith('.mjs')) return 'node';
  if (n.endsWith('.ps1')) return 'powershell -File';
  if (n.endsWith('.bat') || n.endsWith('.cmd')) return '';
  return null;
}

/**
 * Decide una acción a partir de los eventos que escribieron el artefacto.
 * Un JavaScript solo llega a Node cuando su contenido lo demuestra; si el
 * contenido o una página compañera demuestra DOM, la UI abre esa página.
 */
export function artifactAction(events: OrderEvent[], path: string): ArtifactAction {
  const name = basename(path);
  if (!/\.(?:js|mjs)$/i.test(name)) return { runner: runnerFor(name) };

  const content = fileWrittenContent(events, path);
  const companion = htmlCompanion(events, path, name);
  const browserScript = /\b(?:document|window|HTMLElement|customElements)\s*\.|\b(?:querySelector|addEventListener)\s*\(/.test(content);
  if (companion && (browserScript || companion.referencesScript)) {
    return { page: companion.path, runner: null };
  }
  // Un bundle web puede incluir `require` para compatibilidad. Si usa DOM,
  // nunca se degrada a Node solo porque aún no se escribió su HTML compañero.
  if (browserScript) return { runner: null };

  const nodeScript = /(?:^#!.*\bnode\b|\brequire\s*\(|\bprocess\.|\bmodule\.exports\b|from\s+['\"]node:|import\s+['\"]node:)/m.test(content);
  return { runner: nodeScript ? 'node' : null };
}

function fileWrittenContent(events: OrderEvent[], path: string): string {
  const event = [...events].reverse().find((ev) => {
    if (String(ev.kind ?? '') !== 'file_written') return false;
    const p = eventPayload(ev);
    return String(p.file_path ?? p.artifact_name ?? '') === path;
  });
  if (!event) return '';
  const p = eventPayload(event);
  for (const key of ['content', 'contents', 'text', 'body']) {
    if (typeof p[key] === 'string') return p[key] as string;
  }
  return '';
}

function htmlCompanion(events: OrderEvent[], scriptPath: string, scriptName: string): { path: string; referencesScript: boolean } | undefined {
  const directory = dirname(scriptPath);
  for (const ev of events) {
    if (String(ev.kind ?? '') !== 'file_written') continue;
    const p = eventPayload(ev);
    const path = String(p.file_path ?? p.artifact_name ?? '');
    if (!/\.html?$/i.test(path) || dirname(path) !== directory) continue;
    const content = fileWrittenContent(events, path);
    const candidate = { path, referencesScript: htmlReferencesLocalScript(content, scriptName) };
    if (candidate.referencesScript) return candidate;
  }
  return undefined;
}

function basename(path: string): string {
  const slash = Math.max(path.lastIndexOf('\\'), path.lastIndexOf('/'));
  return slash >= 0 ? path.slice(slash + 1) : path;
}

function dirname(path: string): string {
  const normalized = path.replace(/\\/g, '/');
  const slash = normalized.lastIndexOf('/');
  return (slash >= 0 ? normalized.slice(0, slash) : '').toLowerCase();
}

function htmlReferencesLocalScript(content: string, scriptName: string): boolean {
  const sources = content.matchAll(/<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>/gi);
  for (const match of sources) {
    let source = match[1].split(/[?#]/, 1)[0].replace(/\\/g, '/');
    if (/^(?:[a-z]+:|\/\/)/i.test(source)) continue;
    while (source.startsWith('./')) source = source.slice(2);
    if (source.includes('/')) continue;
    if (source.toLowerCase() === scriptName.toLowerCase()) return true;
  }
  return false;
}
