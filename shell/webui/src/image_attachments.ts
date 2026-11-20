/** E5.23: misma cota que el motor. El nombre y el MIME del archivo no son autoridad. */
export const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
export const MAX_ORDER_IMAGES = 4;
const MAX_SIDE = 8192;
const MAX_PIXELS = 32 * 1024 * 1024;

export interface ImageAttachment {
  name: string;
  data_base64: string;
  mime: 'image/png' | 'image/jpeg' | 'image/webp';
  ext: 'png' | 'jpg' | 'webp';
  width: number;
  height: number;
  /** Texto de la página seleccionada: solo contexto, nunca HTML ejecutable. */
  elementContext?: string;
}

type ImageInfo = Pick<ImageAttachment, 'mime' | 'ext' | 'width' | 'height'>;

/** Lee dimensiones antes de decodificar para rechazar bombas de píxeles. */
export function inspectImageBytes(bytes: Uint8Array): ImageInfo {
  if (bytes.length === 0) throw new Error('La imagen está vacía.');
  if (bytes.length > MAX_IMAGE_BYTES) throw new Error('La imagen supera 5 MB.');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const signature = (start: number, values: number[]) => values.every((v, i) => bytes[start + i] === v);
  const dims = (mime: ImageInfo['mime'], ext: ImageInfo['ext'], width: number, height: number): ImageInfo => {
    if (!width || !height || width > MAX_SIDE || height > MAX_SIDE || width * height > MAX_PIXELS) {
      throw new Error('La imagen tiene dimensiones inválidas (máximo 8192 por lado y 32 millones de píxeles).');
    }
    return { mime, ext, width, height };
  };
  if (signature(0, [137, 80, 78, 71, 13, 10, 26, 10])) {
    if (bytes.length < 33 || view.getUint32(8) !== 13 || !signature(12, [73, 72, 68, 82])) {
      throw new Error('Cabecera PNG inválida o truncada.');
    }
    return dims('image/png', 'png', view.getUint32(16), view.getUint32(20));
  }
  if (signature(0, [255, 216])) {
    let pos = 2;
    while (pos < bytes.length) {
      if (bytes[pos++] !== 255) break;
      while (pos < bytes.length && bytes[pos] === 255) pos++;
      const marker = bytes[pos++];
      if (marker === 217 || marker === 218 || marker === undefined) break;
      if (marker === 1 || (marker >= 208 && marker <= 215)) continue;
      if (pos + 2 > bytes.length) break;
      const length = view.getUint16(pos);
      if (length < 2 || pos + length > bytes.length) break;
      if ([192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207].includes(marker)) {
        if (length < 8) break;
        return dims('image/jpeg', 'jpg', view.getUint16(pos + 5), view.getUint16(pos + 3));
      }
      pos += length;
    }
    throw new Error('Cabecera JPEG inválida o truncada.');
  }
  if (signature(0, [82, 73, 70, 70]) && signature(8, [87, 69, 66, 80])) {
    if (bytes.length < 25 || view.getUint32(4, true) + 8 !== bytes.length || view.getUint32(16, true) + 20 > bytes.length) {
      throw new Error('Cabecera WebP inválida o truncada.');
    }
    if (signature(12, [86, 80, 56, 88]) && bytes.length >= 30 && view.getUint32(16, true) >= 10) {
      const width = 1 + bytes[24] + (bytes[25] << 8) + (bytes[26] << 16);
      const height = 1 + bytes[27] + (bytes[28] << 8) + (bytes[29] << 16);
      return dims('image/webp', 'webp', width, height);
    }
    if (signature(12, [86, 80, 56, 32]) && bytes.length >= 30 && signature(23, [157, 1, 42]) && view.getUint32(16, true) >= 10) {
      return dims('image/webp', 'webp', view.getUint16(26, true) & 0x3fff, view.getUint16(28, true) & 0x3fff);
    }
    if (signature(12, [86, 80, 56, 76]) && bytes[20] === 47 && view.getUint32(16, true) >= 5) {
      const packed = view.getUint32(21, true);
      return dims('image/webp', 'webp', 1 + (packed & 0x3fff), 1 + ((packed >>> 14) & 0x3fff));
    }
    throw new Error('Cabecera WebP inválida o truncada.');
  }
  throw new Error('Solo se aceptan imágenes PNG, JPEG o WebP por sus bytes mágicos.');
}

/** Valida cabecera y decodificación real antes de generar el transporte acotado. */
export async function readImageAttachment(file: File, imageCount: number): Promise<ImageAttachment> {
  if (imageCount >= MAX_ORDER_IMAGES) throw new Error('Máximo 4 imágenes por orden.');
  if (file.size > MAX_IMAGE_BYTES) throw new Error('La imagen supera 5 MB.');
  const bytes = new Uint8Array(await file.arrayBuffer());
  const info = inspectImageBytes(bytes);
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(new Blob([bytes], { type: info.mime }), { imageOrientation: 'none' });
  } catch (error) {
    throw new Error(`No se puede decodificar la imagen: ${String(error)}`);
  }
  try {
    if (bitmap.width !== info.width || bitmap.height !== info.height) throw new Error('Las dimensiones de la imagen no coinciden con su cabecera.');
  } finally {
    bitmap.close();
  }
  let binary = '';
  for (let start = 0; start < bytes.length; start += 8192) binary += String.fromCharCode(...bytes.subarray(start, start + 8192));
  return { name: file.name.slice(0, 255), data_base64: btoa(binary), ...info };
}
