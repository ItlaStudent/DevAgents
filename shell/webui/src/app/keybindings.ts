/**
 * F6 (10-nov): atajos de teclado personalizables.
 *
 * Cada comando de la paleta puede tener un atajo por defecto (`shortcut`) y el
 * usuario puede cambiarlo o quitarlo; lo elegido se guarda en localStorage
 * (`devagents.keybindings.v1`, solo comodidad de este equipo). Hay UN único
 * despachador en fase de captura: antes de esto cada atajo vivía en un
 * manejador fijo distinto de main.ts y cambiarlos era imposible.
 */
export interface BindableCommand {
  id: string;
  label: string;
  category?: string;
  /** Atajo por defecto (p. ej. «Ctrl+Shift+S»). */
  shortcut?: string;
  action: () => void;
}

export const KEYBINDINGS_STORAGE_KEY = 'devagents.keybindings.v1';

/** id → atajo elegido; `''` significa «sin atajo». */
type Overrides = Record<string, string>;

let commands: BindableCommand[] = [];

function readOverrides(): Overrides {
  try {
    const raw = window.localStorage.getItem(KEYBINDINGS_STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return {};
    const out: Overrides = {};
    for (const [k, v] of Object.entries(parsed)) if (typeof v === 'string') out[k] = normalizeCombo(v);
    return out;
  } catch {
    return {};
  }
}

function writeOverrides(o: Overrides): void {
  try { window.localStorage.setItem(KEYBINDINGS_STORAGE_KEY, JSON.stringify(o)); } catch { /* comodidad opcional */ }
}

const MOD_ORDER = ['Ctrl', 'Alt', 'Shift'] as const;

/** Forma canónica: «Ctrl+Alt+Shift+Tecla», con la tecla en mayúscula. */
export function normalizeCombo(combo: string): string {
  if (!combo) return '';
  const raw = combo.trim();
  // «Ctrl++» termina en el propio «+».
  const endsWithPlus = raw.endsWith('++') || raw === '+';
  const parts = (endsWithPlus ? raw.slice(0, -1) : raw).split('+').map((p) => p.trim()).filter(Boolean);
  const mods = new Set<string>();
  let key = endsWithPlus ? '+' : '';
  for (const p of parts) {
    const low = p.toLowerCase();
    if (low === 'ctrl' || low === 'control' || low === 'cmd' || low === 'meta') mods.add('Ctrl');
    else if (low === 'alt' || low === 'option') mods.add('Alt');
    else if (low === 'shift' || low === 'mayús' || low === 'mayus') mods.add('Shift');
    else key = p;
  }
  key = canonicalKey(key);
  if (key === '+') mods.delete('Shift');
  return [...MOD_ORDER.filter((m) => mods.has(m)), key].filter(Boolean).join('+');
}

function canonicalKey(k: string): string {
  if (!k) return '';
  const map: Record<string, string> = {
    '=': '+', arrowleft: '←', arrowright: '→', arrowup: '↑', arrowdown: '↓', left: '←', right: '→', up: '↑', down: '↓',
    ' ': 'Espacio', space: 'Espacio', espacio: 'Espacio', escape: 'Esc', esc: 'Esc', enter: 'Enter', return: 'Enter',
    tab: 'Tab', backspace: 'Retroceso', delete: 'Supr', del: 'Supr', home: 'Inicio', end: 'Fin', pageup: 'RePág', pagedown: 'AvPág',
    ',': ',', '.': '.', '/': '/', '-': '-', '+': '+',
  };
  const low = k.toLowerCase();
  if (map[low] !== undefined) return map[low];
  if (/^f\d{1,2}$/i.test(k)) return k.toUpperCase();
  return k.length === 1 ? k.toUpperCase() : k.charAt(0).toUpperCase() + k.slice(1);
}

/** Combinación de un evento de teclado, o '' si solo se pulsó un modificador. */
export function comboFromEvent(e: KeyboardEvent): string {
  if (['Control', 'Alt', 'Shift', 'Meta', 'AltGraph'].includes(e.key)) return '';
  const mods: string[] = [];
  if (e.ctrlKey || e.metaKey) mods.push('Ctrl');
  if (e.altKey) mods.push('Alt');
  if (e.shiftKey) mods.push('Shift');
  return normalizeCombo([...mods, e.key === '+' ? '' : e.key].filter(Boolean).join('+') + (e.key === '+' ? '++' : ''));
}

/** Un atajo despachable debe llevar Ctrl o Alt, o ser una tecla de función. */
export function isAssignable(combo: string): boolean {
  return /(^|\+)(Ctrl|Alt)\+/.test(combo) || /(^|\+)F\d{1,2}$/.test(combo);
}

export function registerBindableCommands(list: BindableCommand[]): void {
  commands = list.slice();
}

export function bindableCommands(): BindableCommand[] {
  return commands.slice();
}

/** Atajo vigente de un comando (el del usuario si lo cambió). */
export function effectiveShortcut(id: string, fallback?: string): string {
  const o = readOverrides();
  if (Object.prototype.hasOwnProperty.call(o, id)) return o[id];
  const cmd = commands.find((c) => c.id === id);
  return normalizeCombo(cmd?.shortcut ?? fallback ?? '');
}

export function isCustomized(id: string): boolean {
  return Object.prototype.hasOwnProperty.call(readOverrides(), id);
}

/**
 * Asigna `combo` a `id`. Si otro comando lo tenía, se le quita (y se devuelve
 * su id para avisar). `combo === ''` deja el comando sin atajo.
 */
export function setShortcut(id: string, combo: string): string | null {
  const target = normalizeCombo(combo);
  const o = readOverrides();
  let displaced: string | null = null;
  if (target) {
    for (const c of commands) {
      if (c.id !== id && effectiveShortcut(c.id) === target) {
        o[c.id] = '';
        displaced = c.id;
      }
    }
  }
  const cmd = commands.find((c) => c.id === id);
  if (normalizeCombo(cmd?.shortcut ?? '') === target) delete o[id];
  else o[id] = target;
  writeOverrides(o);
  return displaced;
}

export function resetShortcut(id?: string): void {
  if (!id) { writeOverrides({}); return; }
  const o = readOverrides();
  delete o[id];
  writeOverrides(o);
}

let installed = false;

/** Despachador único, en captura (antes de Monaco y de los campos de texto). */
export function installKeybindings(target: Document = document): void {
  if (installed) return;
  installed = true;
  target.addEventListener('keydown', (e) => {
    if ((e as KeyboardEvent & { daRecording?: boolean }).daRecording) return;
    if (document.body?.dataset.recordingShortcut === '1') return;
    const combo = comboFromEvent(e);
    if (!combo || !isAssignable(combo)) return;
    // La terminal recibe sus propias teclas (Ctrl+C, Ctrl+L…).
    if ((e.target as HTMLElement | null)?.closest?.('.xterm')) return;
    const cmd = commands.find((c) => effectiveShortcut(c.id) === combo);
    if (!cmd) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    try { cmd.action(); } catch (error) { console.error('[atajo]', cmd.id, error); }
  }, true);
}
