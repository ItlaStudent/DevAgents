/**
 * Pantalla de arranque (maqueta v2, página 4; decisión del propietario del 8-nov):
 * solo el icono aprobado (`01-Marca/Logo-ico 2.png`, reducido a
 * `brand/splash.webp`), sin texto, mientras el motor se prepara; desaparece en
 * cuanto responde. Con un fundido corto que respeta «reducir movimiento».
 * Se puede apagar en Configuración › Apariencia › Ventana.
 *
 * Va colgada de <html> y no de <body>: `renderLayout` reescribe el body
 * entero al pintar la cabina y se la llevaría por delante.
 */
export const SPLASH_KEY = 'devagents.splash.v1';

export function splashEnabled(): boolean {
  try {
    return localStorage.getItem(SPLASH_KEY) !== 'off';
  } catch {
    return true;
  }
}

export function setSplashEnabled(on: boolean): void {
  try {
    if (on) localStorage.removeItem(SPLASH_KEY);
    else localStorage.setItem(SPLASH_KEY, 'off');
  } catch {
    /* sin almacenamiento: vale el valor por defecto */
  }
}

let node: HTMLElement | null = null;
let safety: ReturnType<typeof setTimeout> | null = null;

/** Muestra el icono. Tope de 10 s: nunca tapa una cabina que ya funciona. */
export function showBootSplash(doc: Document = document): void {
  if (node || !splashEnabled()) return;
  const el = doc.createElement('div');
  el.id = 'boot-splash';
  el.setAttribute('aria-hidden', 'true');
  const img = doc.createElement('img');
  img.src = 'brand/splash.webp';
  img.alt = '';
  img.className = 'boot-splash__logo';
  el.appendChild(img);
  doc.documentElement.appendChild(el);
  node = el;
  safety = setTimeout(() => hideBootSplash(), 10000);
}

/** Quita el icono con un fundido corto (o al instante si se pidió menos movimiento). */
export function hideBootSplash(): void {
  if (safety) clearTimeout(safety);
  safety = null;
  const el = node;
  node = null;
  if (!el) return;
  el.classList.add('is-leaving');
  setTimeout(() => el.remove(), 260);
}

export const BOOT_SPLASH_CSS = `
#boot-splash {
  position: fixed; inset: 0; z-index: 100000; display: grid; place-items: center;
  background: radial-gradient(ellipse at center, #121110 0, #070707 70%);
  transition: opacity .25s ease;
}
#boot-splash.is-leaving { opacity: 0; pointer-events: none; }
#boot-splash .boot-splash__logo {
  width: 200px; height: 200px; border-radius: 44px;
  animation: boot-splash-in .6s ease both;
}
@keyframes boot-splash-in { from { opacity: 0; transform: scale(.96); } to { opacity: 1; transform: scale(1); } }
@media (prefers-reduced-motion: reduce) {
  #boot-splash { transition: none; }
  #boot-splash .boot-splash__logo { animation: none; }
}
`;
