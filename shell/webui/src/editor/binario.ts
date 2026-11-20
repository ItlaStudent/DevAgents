/**
 * ¿Es esto texto o un archivo binario leído como texto?
 *
 * 22-09: abrir `catalog.db` (SQLite) desde el explorador lo pintaba en el
 * editor como texto: bytes de control en cajas rojas de Monaco y signos «�»
 * por todas partes. Peor que feo: el editor lo dejaba editar, y guardar con
 * Ctrl+S reescribía la base de datos con esa versión «texto» — corrupta.
 *
 * Mismo criterio que git para decidir si un archivo es binario: un byte NUL
 * en los primeros 8 000 caracteres. Se añade una segunda señal para los
 * binarios sin NUL al principio: más de un 10 % de caracteres de control o
 * de sustitución (U+FFFD, lo que queda de una secuencia que no es UTF-8).
 */
const MUESTRA = 8000;
const UMBRAL_RAROS = 0.1;

export function pareceBinario(texto: string): boolean {
  const muestra = texto.slice(0, MUESTRA);
  if (muestra.length === 0) return false;
  if (muestra.includes('\u0000')) return true;
  let raros = 0;
  for (let i = 0; i < muestra.length; i++) {
    const c = muestra.charCodeAt(i);
    // Tabulador, saltos de línea, retorno y salto de página son texto.
    const control = c < 0x20 && c !== 0x09 && c !== 0x0a && c !== 0x0d && c !== 0x0c;
    if (control || c === 0xfffd) raros++;
  }
  return raros / muestra.length > UMBRAL_RAROS;
}
