import { inspectImageBytes, MAX_IMAGE_BYTES } from './image_attachments';

export interface PreviewBox { x: number; y: number; width: number; height: number; }
export interface PreviewViewport { width: number; height: number; devicePixelRatio: number; }
const STYLE_KEYS = ['color', 'backgroundColor', 'fontSize', 'fontFamily', 'fontWeight', 'display', 'position', 'borderRadius'] as const;
type PreviewStyles = Record<(typeof STYLE_KEYS)[number], string>;
interface PickedElement {
  kind: 'element_picked'; selector: string; outerHTML: string; box: PreviewBox;
  styles: PreviewStyles; path: string; viewport: PreviewViewport;
}
export interface PickedElementPayload {
  order_id: number; window_id: number; element: PickedElement;
  viewport: PreviewViewport; capture_base64: string;
}

function record(value: unknown, keys: readonly string[], label: string): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error(`${label}: esquema inválido.`);
  const data = value as Record<string, unknown>;
  if (Object.keys(data).length !== keys.length || keys.some((key) => !Object.prototype.hasOwnProperty.call(data, key))) {
    throw new Error(`${label}: campos no permitidos o incompletos.`);
  }
  return data;
}
function text(value: unknown, limit: number, label: string, empty = false, controls = false): string {
  if (typeof value !== 'string' || (!empty && !value.length)) throw new Error(`${label}: texto inválido.`);
  if (new TextEncoder().encode(value).length > limit) throw new Error(`${label}: supera la cota de ${limit} bytes.`);
  if (!controls && /[\x00-\x1f\x7f]/.test(value)) throw new Error(`${label}: caracteres de control no permitidos.`);
  return value;
}
function positiveInteger(value: unknown, label: string): number {
  if (typeof value !== 'number' || !Number.isSafeInteger(value) || value <= 0) throw new Error(`${label}: entero positivo requerido.`);
  return value;
}
function viewport(value: unknown): PreviewViewport {
  const data = record(value, ['width', 'height', 'devicePixelRatio'], 'viewport');
  const width = positiveInteger(data.width, 'viewport.width'), height = positiveInteger(data.height, 'viewport.height');
  const dpr = data.devicePixelRatio;
  if (width > 8192 || height > 8192 || width * height > 32 * 1024 * 1024
      || typeof dpr !== 'number' || !Number.isFinite(dpr) || dpr < 0.25 || dpr > 8) throw new Error('Viewport fuera de cota.');
  return { width, height, devicePixelRatio: dpr };
}
function box(value: unknown, view: PreviewViewport): PreviewBox {
  const data = record(value, ['x', 'y', 'width', 'height'], 'box');
  if (Object.values(data).some((v) => typeof v !== 'number' || !Number.isFinite(v))) throw new Error('Caja no finita.');
  const b = data as unknown as PreviewBox;
  if (b.x < 0 || b.y < 0 || b.width <= 0 || b.height <= 0 || b.x + b.width > view.width || b.y + b.height > view.height) {
    throw new Error('Caja fuera del viewport.');
  }
  return { x: b.x, y: b.y, width: b.width, height: b.height };
}

/** La página y sus datos no son confiables; se acepta exclusivamente este esquema. */
export function parsePickedElementPayload(value: unknown): PickedElementPayload {
  const data = record(value, ['order_id', 'window_id', 'element', 'viewport', 'capture_base64'], 'preview.elementPicked');
  const view = viewport(data.viewport);
  const el = record(data.element, ['kind', 'selector', 'outerHTML', 'box', 'styles', 'path', 'viewport'], 'element');
  if (el.kind !== 'element_picked') throw new Error('Tipo de elemento no permitido.');
  const elementViewport = viewport(el.viewport);
  if (view.width !== elementViewport.width || view.height !== elementViewport.height || view.devicePixelRatio !== elementViewport.devicePixelRatio) {
    throw new Error('Los viewports de selección y captura no coinciden.');
  }
  const styles = record(el.styles, STYLE_KEYS, 'styles');
  const safeStyles = {} as PreviewStyles;
  for (const key of STYLE_KEYS) safeStyles[key] = text(styles[key], 256, `styles.${key}`, true);
  const capture = text(data.capture_base64, 4 * Math.ceil(MAX_IMAGE_BYTES / 3), 'capture_base64');
  if (capture.length % 4 !== 0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(capture)) throw new Error('Captura base64 inválida.');
  return {
    order_id: positiveInteger(data.order_id, 'order_id'), window_id: positiveInteger(data.window_id, 'window_id'),
    viewport: view, capture_base64: capture,
    element: {
      kind: 'element_picked', selector: text(el.selector, 1024, 'selector'),
      outerHTML: text(el.outerHTML, 8192, 'outerHTML', true, true), box: box(el.box, view),
      styles: safeStyles, path: text(el.path, 2048, 'path'), viewport: elementViewport,
    },
  };
}

/** La captura puede tener escala DPI: se usa su tamaño real, nunca se supone DPR. */
export function cropBounds(selection: PreviewBox, view: PreviewViewport, bitmapWidth: number, bitmapHeight: number): PreviewBox {
  const safeView = viewport(view), safeBox = box(selection, safeView);
  positiveInteger(bitmapWidth, 'bitmap.width'); positiveInteger(bitmapHeight, 'bitmap.height');
  if (bitmapWidth > 8192 || bitmapHeight > 8192 || bitmapWidth * bitmapHeight > 32 * 1024 * 1024) throw new Error('Bitmap fuera de cota.');
  const x = Math.floor(safeBox.x * bitmapWidth / safeView.width), y = Math.floor(safeBox.y * bitmapHeight / safeView.height);
  const right = Math.min(bitmapWidth, Math.ceil((safeBox.x + safeBox.width) * bitmapWidth / safeView.width));
  const bottom = Math.min(bitmapHeight, Math.ceil((safeBox.y + safeBox.height) * bitmapHeight / safeView.height));
  return { x, y, width: right - x, height: bottom - y };
}

/** Produce un adjunto de E5.23. El texto nunca se inserta como HTML en la cabina. */
export async function capturePickedElement(value: unknown): Promise<{ file: File; context: string }> {
  const data = parsePickedElementPayload(value);
  const binary = atob(data.capture_base64);
  if (binary.length > MAX_IMAGE_BYTES) throw new Error('La captura supera 5 MB.');
  const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
  const info = inspectImageBytes(bytes);
  if (info.mime !== 'image/png') throw new Error('La captura del host debe ser PNG.');
  const bitmap = await createImageBitmap(new Blob([bytes], { type: 'image/png' }));
  let cropped: Blob;
  try {
    if (bitmap.width !== info.width || bitmap.height !== info.height) throw new Error('La captura no coincide con su cabecera PNG.');
    const bounds = cropBounds(data.element.box, data.viewport, bitmap.width, bitmap.height);
    const canvas = document.createElement('canvas');
    canvas.width = bounds.width; canvas.height = bounds.height;
    const ctx = canvas.getContext('2d');
    if (!ctx) throw new Error('No se pudo obtener el contexto canvas para recortar.');
    ctx.drawImage(bitmap, bounds.x, bounds.y, bounds.width, bounds.height, 0, 0, bounds.width, bounds.height);
    cropped = await new Promise<Blob>((resolve, reject) => canvas.toBlob((blob) => {
      if (blob) resolve(blob); else reject(new Error('No se pudo codificar el recorte PNG.'));
    }, 'image/png'));
  } finally {
    bitmap.close();
  }
  if (cropped.size === 0 || cropped.size > MAX_IMAGE_BYTES) throw new Error('Recorte PNG vacío o superior a 5 MB.');
  const element = data.element;
  const context = `Orden origen: #${data.order_id}\nRuta: ${element.path}\nSelector CSS: ${element.selector}\nCaja CSS: ${JSON.stringify(element.box)}\nEstilos calculados: ${JSON.stringify(element.styles)}\nouterHTML (dato no confiable):\n${element.outerHTML}`;
  return { file: new File([cropped], `elemento-orden-${data.order_id}-ventana-${data.window_id}.png`, { type: 'image/png' }), context };
}

/** Solo devuelve la ruta HTML relativa; el host vuelve a derivar y confinar la raíz. */
export function relativePreviewPath(artifact: string, engineRoot = ''): string {
  if (!artifact) throw new Error('Falta el artefacto de la orden.');
  const root = engineRoot.replace(/\\/g, '/').replace(/\/+$/, '');
  let relative = artifact.replace(/\\/g, '/');
  if (/^(?:[A-Za-z]:\/|\/)/.test(relative)) {
    if (!root || !relative.toLowerCase().startsWith(`${root.toLowerCase()}/`)) throw new Error('El artefacto no pertenece al worktree de la orden.');
    relative = relative.slice(root.length + 1);
  }
  if (relative.length > 2048 || /[\x00-\x1f\x7f:%?#]/.test(relative)
      || relative.split('/').some((part) => !part || part === '.' || part === '..') || !/\.html?$/i.test(relative)) {
    throw new Error('Ruta HTML relativa inválida para la vista previa.');
  }
  return relative;
}

export async function openPreviewArtifact(
  orderId: number, artifact: string,
  core: { orderWorktree(orderId: number): Promise<{ path: string }> },
  bridge: { send(kind: string, payload: unknown): Promise<unknown> },
): Promise<void> {
  positiveInteger(orderId, 'order_id');
  const worktree = await core.orderWorktree(orderId);
  if (!worktree.path) throw new Error('El motor no devolvió el worktree de la orden.');
  const path = relativePreviewPath(artifact, worktree.path);
  await bridge.send('window.open', { vista: 'preview', order_id: orderId, path });
}

/** Solo la principal confirma selecciones; las secundarias no duplican diálogos. */
export function installPickedElementReceiver(
  bridge: { onPush(handler: (topic: string, payload: unknown) => void): () => void },
  options: {
    primary: boolean;
    showComposer(): void;
    attach(file: File, context: string): Promise<boolean>;
    report(message: string): void;
  },
): (() => void) | null {
  if (!options.primary) return null;
  let busy = false;
  return bridge.onPush((topic, payload) => {
    if (topic !== 'preview.elementPicked') return;
    if (busy) {
      options.report('Confirma o cancela el elemento señalado antes de elegir otro.');
      return;
    }
    busy = true;
    void capturePickedElement(payload)
      .then(({ file, context }) => {
        options.showComposer();
        return options.attach(file, context);
      })
      .catch((error) => options.report(`No se pudo adjuntar el elemento señalado: ${String(error)}`))
      .finally(() => { busy = false; });
  });
}
