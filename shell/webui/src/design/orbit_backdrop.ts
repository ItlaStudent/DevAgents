/**
 * Fondo de la pantalla de inicio: líneas que brotan del eje central.
 *
 * Con el tema negro, la pantalla vacía era un agujero negro con el logo en
 * medio. El logo ya cuenta la idea —un coordinador del que se desprenden
 * ramas con nodos, cada una un subagente—; este fondo la prolonga hasta el
 * borde de la vista, muy tenue, para que el vacío tenga profundidad sin
 * competir con el texto.
 *
 * Determinista (semilla fija): la misma figura en cada arranque, nada que
 * parpadee al repintar. Hereda `currentColor`, así que sigue al tema. La
 * animación es un pulso lento por unas pocas ramas y se apaga con
 * `prefers-reduced-motion` (ver .orbit-backdrop en stylesheet.ts).
 */

/** PRNG pequeño y estable (mulberry32). */
function prng(semilla: number): () => number {
  let a = semilla >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const f = (n: number): string => n.toFixed(1);

export function orbitBackdrop(): string {
  const rnd = prng(20260922);
  const C = 500; // centro del lienzo 1000×1000
  const RAYOS = 30;
  let ramas = '';
  let nodos = '';
  let pulsos = '';

  for (let i = 0; i < RAYOS; i++) {
    const ang = (i / RAYOS) * Math.PI * 2 + (rnd() - 0.5) * 0.12;
    const r0 = 118 + rnd() * 18; // nace fuera del emblema
    const r1 = 250 + rnd() * 230;
    const curva = (rnd() - 0.5) * 0.5; // cuánto se tuerce la rama
    const x0 = C + Math.cos(ang) * r0;
    const y0 = C + Math.sin(ang) * r0;
    const x1 = C + Math.cos(ang + curva) * r1;
    const y1 = C + Math.sin(ang + curva) * r1;
    const rm = (r0 + r1) / 2;
    const cx = C + Math.cos(ang + curva * 0.2) * rm;
    const cy = C + Math.sin(ang + curva * 0.2) * rm;
    const d = `M${f(x0)} ${f(y0)} Q${f(cx)} ${f(cy)} ${f(x1)} ${f(y1)}`;
    ramas += `<path d="${d}"/>`;
    nodos += `<circle cx="${f(x1)}" cy="${f(y1)}" r="${f(2 + rnd() * 2.2)}"/>`;

    // Una bifurcación en algo más de la mitad de las ramas: un subagente que
    // a su vez delega.
    if (rnd() < 0.55) {
      const t = 0.45 + rnd() * 0.25;
      const bx = (1 - t) * (1 - t) * x0 + 2 * (1 - t) * t * cx + t * t * x1;
      const by = (1 - t) * (1 - t) * y0 + 2 * (1 - t) * t * cy + t * t * y1;
      const giro = (rnd() < 0.5 ? -1 : 1) * (0.35 + rnd() * 0.35);
      const largo = 40 + rnd() * 70;
      const ex = bx + Math.cos(ang + curva + giro) * largo;
      const ey = by + Math.sin(ang + curva + giro) * largo;
      ramas += `<path d="M${f(bx)} ${f(by)} L${f(ex)} ${f(ey)}"/>`;
      nodos += `<circle cx="${f(ex)}" cy="${f(ey)}" r="1.6"/>`;
    }

    // Un pulso cada cinco ramas: la señal que sale del coordinador.
    if (i % 5 === 0) {
      const retraso = (rnd() * 6).toFixed(2);
      pulsos += `<path class="orbit-backdrop__pulse" d="${d}" style="animation-delay:-${retraso}s"/>`;
    }
  }

  return (
    `<svg class="orbit-backdrop" viewBox="0 0 1000 1000" preserveAspectRatio="xMidYMid slice" aria-hidden="true">` +
    `<defs><radialGradient id="orbit-halo"><stop offset="0" stop-color="currentColor" stop-opacity="0.07"/>` +
    `<stop offset="1" stop-color="currentColor" stop-opacity="0"/></radialGradient></defs>` +
    `<circle cx="${C}" cy="${C}" r="420" fill="url(#orbit-halo)"/>` +
    `<g class="orbit-backdrop__ramas" fill="none" stroke="currentColor" stroke-width="1" stroke-linecap="round">${ramas}</g>` +
    `<g class="orbit-backdrop__nodos" fill="currentColor">${nodos}</g>` +
    `<g fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round">${pulsos}</g>` +
    `</svg>`
  );
}
