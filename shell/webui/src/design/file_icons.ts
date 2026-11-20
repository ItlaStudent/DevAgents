import { icons } from './icons';

/**
 * Icono y color por tipo de archivo para el explorador.
 *
 * Dos criterios, y el primero manda:
 *
 * 1. **La forma distingue, el color acompaña.** Cada familia tiene su propio
 *    trazo (código, documento, datos, imagen, configuración, empaquetado), así
 *    que el árbol se lee igual de bien sin percibir el color. Un esquema que
 *    solo cambia de tono deja fuera a quien no distingue rojo y verde.
 * 2. **Los colores salen de los tokens del tema**, nunca literales, para que el
 *    explorador siga siendo coherente en los ocho temas.
 */
export interface FileIcon {
  svg: string;
  color: string;
}

const EXT: Array<{ test: RegExp; icon: (s?: number) => string; color: string }> = [
  // Código
  { test: /\.(ts|tsx|js|mjs|cjs|jsx)$/i, icon: icons.fileCode, color: 'var(--accent)' },
  { test: /\.(zig)$/i, icon: icons.fileCode, color: 'var(--warning)' },
  { test: /\.(py)$/i, icon: icons.fileCode, color: 'var(--success)' },
  { test: /\.(c|h|cpp|hpp|cc|cxx)$/i, icon: icons.fileCode, color: 'var(--accent)' },
  { test: /\.(rs|go|java|kt|rb|php|cs|swift)$/i, icon: icons.fileCode, color: 'var(--accent)' },
  { test: /\.(sh|bash|ps1|bat|cmd)$/i, icon: icons.terminal, color: 'var(--fg-muted)' },
  // Datos y configuración
  { test: /\.(json|jsonc)$/i, icon: icons.fileData, color: 'var(--warning)' },
  { test: /\.(ya?ml|toml|ini|cfg|conf|properties|env)$/i, icon: icons.fileConfig, color: 'var(--fg-muted)' },
  { test: /\.(db|sqlite3?|csv|tsv|parquet)$/i, icon: icons.fileData, color: 'var(--success)' },
  // Documentos
  { test: /\.(md|markdown|txt|rst|adoc)$/i, icon: icons.fileDoc, color: 'var(--fg-muted)' },
  { test: /\.(pdf|docx?|odt)$/i, icon: icons.fileDoc, color: 'var(--danger)' },
  // Imágenes y multimedia
  { test: /\.(png|jpe?g|gif|webp|bmp|ico|svg|avif)$/i, icon: icons.fileImage, color: 'var(--accent)' },
  // Empaquetados y binarios
  { test: /\.(zip|tar|gz|7z|rar|exe|dll|pdb|obj|lib|so|dylib)$/i, icon: icons.fileArchive, color: 'var(--fg-subtle)' },
];

/** Nombres exactos que merecen icono propio por lo que significan. */
const BY_NAME: Record<string, { icon: (s?: number) => string; color: string }> = {
  'package.json': { icon: icons.fileConfig, color: 'var(--danger)' },
  'build.zig': { icon: icons.fileConfig, color: 'var(--warning)' },
  'tsconfig.json': { icon: icons.fileConfig, color: 'var(--accent)' },
  '.gitignore': { icon: icons.fileConfig, color: 'var(--fg-subtle)' },
  'readme.md': { icon: icons.book, color: 'var(--fg-default)' },
};

export function fileIcon(name: string, size = 13): FileIcon {
  const exact = BY_NAME[name.toLowerCase()];
  if (exact) return { svg: exact.icon(size), color: exact.color };
  for (const e of EXT) {
    if (e.test.test(name)) return { svg: e.icon(size), color: e.color };
  }
  return { svg: icons.file(size), color: 'var(--fg-subtle)' };
}

/** Carpeta: abierta o cerrada, en el color de acento suave. */
export function folderIcon(open: boolean, size = 13): FileIcon {
  return {
    svg: open ? icons.folderOpen(size) : icons.folder(size),
    color: 'var(--accent)',
  };
}
