/**
 * E2.17 — menú contextual «Copiar imagen» / «Copiar texto», compartido.
 *
 * Antes vivía solo en MissionControlPanel: el clic derecho sobre una tarjeta
 * del transcript central no abría nada (medido en vivo 2026-09-18). Ahora se
 * instala sobre cualquier contenedor que renderice bloques copiables:
 * `.card, .chat-turn, pre, .task-card, .act-card, .list-item`.
 */
import { notice } from '../design/notice';

let ctxMenuEl: HTMLElement | null = null;

function closeCtxMenu(): void {
  ctxMenuEl?.remove();
  ctxMenuEl = null;
}

function showCopyImageMenu(ev: MouseEvent, target: HTMLElement): void {
  closeCtxMenu();
  const menu = document.createElement('div');
  menu.className = 'ctx-menu';
  menu.innerHTML =
    `<button type="button" class="ctx-menu__item" data-act="copy-img">Copiar imagen</button>` +
    `<button type="button" class="ctx-menu__item" data-act="copy-text">Copiar texto</button>`;
  document.body.appendChild(menu);
  // El menú no puede salirse del viewport: un clic derecho cerca del borde
  // inferior o derecho dejaba los ítems fuera de pantalla e inclicables.
  const mw = menu.offsetWidth || 160;
  const mh = menu.offsetHeight || 80;
  menu.style.left = `${Math.max(4, Math.min(ev.clientX, window.innerWidth - mw - 4))}px`;
  menu.style.top = `${Math.max(4, Math.min(ev.clientY, window.innerHeight - mh - 4))}px`;
  ctxMenuEl = menu;
  const off = () => closeCtxMenu();
  setTimeout(() => {
    document.addEventListener('click', off, { once: true });
    document.addEventListener('contextmenu', off, { once: true });
  }, 0);
  menu.querySelector('[data-act="copy-text"]')?.addEventListener('click', async () => {
    closeCtxMenu();
    try {
      await navigator.clipboard.writeText(target.innerText);
      notice('Texto copiado al portapapeles', 'info');
    } catch {
      notice('El portapapeles no está disponible en este contexto', 'error');
    }
  });
  menu.querySelector('[data-act="copy-img"]')?.addEventListener('click', async () => {
    closeCtxMenu();
    try {
      const blob = await elementToPng(target);
      if (!blob) throw new Error('rasterización vacía');
      await navigator.clipboard.write([new ClipboardItem({ 'image/png': blob })]);
      notice('Imagen copiada al portapapeles', 'info');
    } catch (e) {
      notice('No se pudo copiar la imagen: ' + String(e), 'error');
    }
  });
}

/**
 * DOM → PNG vía SVG foreignObject. El estilo se inyecta como texto porque la
 * hoja externa no aplica dentro de una imagen aislada; las fuentes caen a las
 * genéricas del sistema, que para una tarjeta de texto basta.
 */
async function elementToPng(el: HTMLElement): Promise<Blob | null> {
  const rect = el.getBoundingClientRect();
  const w = Math.max(1, Math.ceil(rect.width));
  const h = Math.max(1, Math.ceil(rect.height));
  let css = '';
  for (const sheet of Array.from(document.styleSheets)) {
    try {
      for (const rule of Array.from(sheet.cssRules)) css += rule.cssText + '\n';
    } catch {
      // Hojas de otro origen no se pueden leer; el resto sí aplica.
    }
  }
  const clone = el.cloneNode(true) as HTMLElement;
  clone.setAttribute('xmlns', 'http://www.w3.org/1999/xhtml');
  clone.style.margin = '0';
  const xhtml = new XMLSerializer().serializeToString(clone);
  const svg =
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">` +
    `<foreignObject width="100%" height="100%">` +
    `<div xmlns="http://www.w3.org/1999/xhtml" style="background:var(--bg-main,#0a0a0a)"><style>${css}</style>${xhtml}</div>` +
    `</foreignObject></svg>`;
  const url = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
  const img = await new Promise<HTMLImageElement>((resolve, reject) => {
    const i = new Image();
    i.onload = () => resolve(i);
    i.onerror = () => reject(new Error('el SVG no cargó'));
    // Sin timeout la promesa no se resuelve jamás si el SVG queda en espera.
    setTimeout(() => reject(new Error('tiempo de rasterización agotado')), 5000);
    i.src = url;
  });
  const scale = Math.min(2, window.devicePixelRatio || 1);
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(w * scale);
  canvas.height = Math.round(h * scale);
  const ctx = canvas.getContext('2d');
  if (!ctx) return null;
  ctx.scale(scale, scale);
  ctx.drawImage(img, 0, 0, w, h);
  return await new Promise<Blob | null>((resolve) => canvas.toBlob((b) => resolve(b), 'image/png'));
}

/** Instala el menú sobre un contenedor: delegado, sobrevive a repintados. */
export function installCopyImageMenu(container: HTMLElement): void {
  container.addEventListener('contextmenu', (ev) => {
    const target = (ev.target as HTMLElement).closest?.(
      '.card, .chat-turn, pre, .task-card, .act-card, .list-item'
    ) as HTMLElement | null;
    if (!target) return;
    ev.preventDefault();
    showCopyImageMenu(ev as MouseEvent, target);
  });
}
