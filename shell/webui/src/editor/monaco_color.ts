/**
 * Un color CSS en la única forma que Monaco sabe leer: `#rrggbb` o
 * `#rrggbbaa`. null si no es ni hexadecimal ni rgb()/rgba().
 *
 * 22-09: Monaco NO entiende `rgba(...)` en un tema, y lo que no entiende lo
 * pinta en rojo puro (`Color.red`, sin avisar). `--border` es rgba en los
 * temas oscuros, así que las guías de sangría, los bordes de los widgets y
 * los espacios visibles salían en #ff0000 en cualquier archivo con sangría.
 */
export const aHex = (v: string): string | null => {
  const t = v.trim();
  if (/^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(t)) return t;
  if (/^#[0-9a-fA-F]{3}$/.test(t)) return '#' + [...t.slice(1)].map((c) => c + c).join('');
  const m = /^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/.exec(t);
  if (!m) return null;
  const rgb = [m[1], m[2], m[3]].map((n) => Math.min(255, +n).toString(16).padStart(2, '0')).join('');
  const a = m[4] === undefined ? '' : Math.round(Math.max(0, Math.min(1, +m[4])) * 255).toString(16).padStart(2, '0');
  return '#' + rgb + a;
};
