/**
 * Iconografia de la cabina: SVG de trazo, 16px, heredando `currentColor`.
 *
 * Sustituye a los emoji del prototipo. Un emoji se pinta con la fuente del
 * sistema, ignora el tema y arrastra el aspecto generico que tenia la maqueta;
 * un SVG de trazo hereda el color del token y pesa lo mismo.
 */

const svg = (paths: string, size = 16): string =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" ` +
  `stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;

/**
 * Marca de DevAgents: el logo real de Ad el auditor, no una imitación.
 *
 * Hasta el 22-09 esto era un SVG de trazo dibujado a mano que «se parecía» al
 * logo. Ahora son recortes del PNG de marca, generados por
 * tools/brand/generate_brand_assets.py y servidos desde dist/brand/:
 *  - glyph.png: la silueta del núcleo (triángulo, anillos y galaxia) sin
 *    teja. Es una MÁSCARA: la pinta `background-color: currentColor`, así
 *    que sigue al tema y al estado del botón como cualquier icono. Antes era
 *    el núcleo sobre su teja oscura, y en un tema claro o rosa se veía como
 *    una foto pegada.
 *  - emblem.png: el logo completo con sus ramas y colores, para 48 px o más.
 */
export const brandMark = (size = 16): string =>
  `<span class="brand-mark" style="width:${size}px;height:${size}px" aria-hidden="true"></span>`;

export const brandEmblem = (size = 64): string =>
  `<img class="brand-emblem" src="brand/emblem.png" width="${size}" height="${size}" alt="DevAgents" draggable="false">`;

export const icons = {
  /** Alias de la marca, para usarla como icono de la vista de agente. */
  brand: (s?: number) => brandMark(s),
  monitor: (s?: number) =>
    svg('<rect x="3" y="4" width="18" height="13" rx="2"/><path d="M8 21h8M12 17v4"/><path d="m7 12 2.5-3 2.5 3.5L14 10l3 4"/>', s),
  // USUARIO-NUEVO A8 (10-nov): `agent` (tres nodos unidos) se usaba para seis
  // conceptos distintos. Cada uno tiene ahora su propio dibujo, con la misma
  // rejilla de 24 y el mismo trazo; ninguno se recicla para otra cosa.
  /** Modelo de IA (selector «Modelo» del compositor): un chip con sus patas. */
  model: (s?: number) =>
    svg('<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9.5 9.5h5v5h-5zM9 2.5V6M15 2.5V6M9 18v3.5M15 18v3.5M2.5 9H6M2.5 15H6M18 9h3.5M18 15h3.5"/>', s),
  /** Modo Agente (planifica y ejecuta): destello grande y uno pequeño. */
  agentMode: (s?: number) =>
    svg('<path d="M10 3.5 11.9 8.6 17 10.5l-5.1 1.9L10 17.5l-1.9-5.1L3 10.5l5.1-1.9z"/><path d="m18 14.5.9 2.1 2.1.9-2.1.9-.9 2.1-.9-2.1-2.1-.9 2.1-.9z"/>', s),
  /**
   * USUARIO-NUEVO B (10-nov): modo «DevAgents». Un nodo que reparte en tres
   * ramas paralelas que vuelven a juntarse (delegar y reunir). Solo este modo.
   */
  delegate: (s?: number) =>
    svg('<circle cx="4.5" cy="12" r="2"/><circle cx="19.5" cy="12" r="2"/><path d="M6.5 12h11M6.2 10.8C9 6 15 6 17.8 10.8M6.2 13.2C9 18 15 18 17.8 13.2"/><circle cx="12" cy="7.4" r="1.2"/><circle cx="12" cy="12" r="1.2"/><circle cx="12" cy="16.6" r="1.2"/>', s),
  /** Sesiones (conversaciones guardadas): dos bocadillos superpuestos. */
  sessions: (s?: number) =>
    svg('<path d="M3 6a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2H8.5L5 16v-3a2 2 0 0 1-2-2z"/><path d="M19 9a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2v3l-3.5-3H11a2 2 0 0 1-2-2"/>', s),
  /** Tarea de un plan: tarjeta con dos casillas marcadas. */
  task: (s?: number) =>
    svg('<rect x="4" y="3" width="16" height="18" rx="2"/><path d="m7.5 9 1.5 1.5L12 7.5M7.5 15.5 9 17l3-3M14.5 9h2.5M14.5 15.5h2.5"/>', s),
  /** Agente externo (una CLI de otra marca): ventana de terminal con salida. */
  externalAgent: (s?: number) =>
    svg('<rect x="3" y="7" width="13" height="13" rx="2"/><path d="m6.5 11.5 2.5 2-2.5 2M11 15.5h2.5M17 3h4v4M21 3l-4.5 4.5"/>', s),
  /** Explorador de archivos: dos documentos apilados (no una carpeta). */
  files: (s?: number) =>
    svg('<path d="M9 3h6l4 4v10a1.5 1.5 0 0 1-1.5 1.5h-8A1.5 1.5 0 0 1 8 17V4.5A1.5 1.5 0 0 1 9.5 3z"/><path d="M15 3v4h4"/><path d="M5 7.5V19a2 2 0 0 0 2 2h8.5"/>', s),
  search: (s?: number) => svg('<circle cx="10.5" cy="10.5" r="6.5"/><path d="m20 20-4.8-4.8"/>', s),
  spaces: (s?: number) =>
    svg('<path d="M4 7.5 12 3l8 4.5v9L12 21l-8-4.5z"/><path d="m4 7.5 8 4.5 8-4.5M12 12v9"/>', s),
  /** Conectores MCP (servidor y sus herramientas): el enchufe. Solo MCP. */
  plug: (s?: number) =>
    svg('<path d="M9 3v6M15 3v6M6 9h12v3a6 6 0 0 1-12 0zM12 18v3"/>', s),
  // USUARIO-NUEVO A8 (10-nov): `plug` servía también para los proveedores de
  // modelos, los receptores de avisos y la app registrada del navegador.
  /** Proveedor de modelos por HTTP (OpenRouter, Cohere…): nube con su enlace. */
  provider: (s?: number) =>
    svg('<path d="M7 17.5a4 4 0 0 1-.6-7.95A5.5 5.5 0 0 1 17 8.6a4.5 4.5 0 0 1 .5 8.9z"/><path d="M9 13.5h6"/>', s),
  /** Receptor de avisos (webhook): tres nodos que se envían el aviso. */
  webhook: (s?: number) =>
    svg('<circle cx="12" cy="6" r="2.5"/><circle cx="6" cy="17" r="2.5"/><circle cx="18" cy="17" r="2.5"/><path d="m10.8 8.3-3.5 6.5M8.5 17h7M13.2 8.3l3.5 6.5"/>', s),
  /** App local registrada (un puerto de localhost): ventana con su puerto. */
  localApp: (s?: number) =>
    svg('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M3 8.5h18"/><circle cx="12" cy="14.5" r="2.2"/>', s),
  settings: (s?: number) =>
    svg(
      '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-1.8-.3 1.6 1.6 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.6 1.6 0 0 0 9 19.4a1.6 1.6 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0 .3-1.8 1.6 1.6 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.6 1.6 0 0 0 4.6 9a1.6 1.6 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 1.8.3H9a1.6 1.6 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.6 1.6 0 0 0 1 1.5 1.6 1.6 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-.3 1.8V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.6 1.6 0 0 0-1.5 1z"/>',
      s
    ),
  bolt: (s?: number) => svg('<path d="M13 2 4 14h7l-1 8 9-12h-7z"/>', s),
  folder: (s?: number) => svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/>', s),
  file: (s?: number) => svg('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>', s),
  chevronRight: (s?: number) => svg('<path d="m9 5 7 7-7 7"/>', s),
  chevronLeft: (s?: number) => svg('<path d="m15 5-7 7 7 7"/>', s),
  chevronDown: (s?: number) => svg('<path d="m5 9 7 7 7-7"/>', s),
  chevronUp: (s?: number) => svg('<path d="m5 15 7-7 7 7"/>', s),
  close: (s?: number) => svg('<path d="M18 6 6 18M6 6l12 12"/>', s),
  minimize: (s?: number) => svg('<path d="M5 12h14"/>', s),
  maximize: (s?: number) => svg('<rect x="5" y="5" width="14" height="14" rx="2"/>', s),
  send: (s?: number) => svg('<path d="M4 12 20 4l-4 16-4.5-6.5z"/><path d="m11.5 13.5 8.5-9.5"/>', s),
  plus: (s?: number) => svg('<path d="M12 5v14M5 12h14"/>', s),
  trash: (s?: number) => svg('<path d="M4 7h16M9 7V5a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2M6 7l1 13a1 1 0 0 0 1 1h8a1 1 0 0 0 1-1l1-13"/>', s),
  refresh: (s?: number) => svg('<path d="M20 11a8 8 0 1 0-.6 4"/><path d="M20 4v7h-7"/>', s),
  check: (s?: number) => svg('<path d="m5 13 4.5 4.5L19 7"/>', s),
  // Commit de git: el circulo del nodo con sus dos enlaces. Se usa en la
  // tarjeta «Cambios» (E4) a 18 px.
  commit: (s?: number) => svg('<circle cx="12" cy="12" r="4"/><path d="M12 3v5M12 16v5"/>', s),
  bell: (s?: number) => svg('<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15z"/><path d="M10 21h4"/>', s),
  alert: (s?: number) => svg('<path d="M12 3 2 20h20z"/><path d="M12 10v4M12 17.2v.1"/>', s),
  play: (s?: number) => svg('<path d="M7 4.5 19 12 7 19.5z"/>', s),
  // Traza de razonamiento. Dos lobulos y una conexion: se lee como cerebro a
  // 13px, que es el tamano al que se usa en el resumen desplegable.
  brain: (s?: number) =>
    svg(
      '<path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-1 5.8V15a3 3 0 0 0 4 2.8V4z"/><path d="M15 4a3 3 0 0 1 3 3 3 3 0 0 1 1 5.8V15a3 3 0 0 1-4 2.8V4z"/><path d="M12 4v16"/>',
      s
    ),
  stop: (s?: number) => svg('<rect x="6" y="6" width="12" height="12" rx="2"/>', s),
  terminal: (s?: number) => svg('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="m7 9 3 3-3 3M13 15h4"/>', s),
  shield: (s?: number) => svg('<path d="M12 3 5 6v6c0 4 3 7.5 7 9 4-1.5 7-5 7-9V6z"/><path d="m9 12 2 2 4-4"/>', s),
  clock: (s?: number) => svg('<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3.5 2"/>', s),
  key: (s?: number) => svg('<circle cx="8" cy="15" r="4"/><path d="m11 12 8-8 2 2-2 2 2 2-2 2-2-2-2 2z"/>', s),
  layers: (s?: number) => svg('<path d="m12 3 9 5-9 5-9-5z"/><path d="m3 13 9 5 9-5M3 17l9 5 9-5"/>', s),
  code: (s?: number) => svg('<path d="m9 8-5 4 5 4M15 8l5 4-5 4"/>', s),
  book: (s?: number) => svg('<path d="M4 5a2 2 0 0 1 2-2h13v18H6a2 2 0 0 1-2-2z"/><path d="M8 3v18"/>', s),
  sidebarRight: (s?: number) =>
    svg('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M15 4v16"/>', s),
  // r4-2: incidencias. En la barra de actividades salia gemela de
  // la carpeta del explorador; la bandeja con su arco se distingue de un
  // vistazo y dice que ahi viven las incidencias del proyecto.
  issues: (s?: number) => svg('<path d="M5 4h14l2 9v7H3v-7z"/><path d="M3 13h5a4 4 0 0 0 8 0h5"/>', s),
  sidebarLeft: (s?: number) =>
    svg('<rect x="3" y="4" width="18" height="16" rx="2"/><path d="M9 4v16"/>', s),
  fork: (s?: number) =>
    svg('<circle cx="6" cy="5" r="2.4"/><circle cx="18" cy="5" r="2.4"/><circle cx="12" cy="19" r="2.4"/><path d="M6 7.4v1.8a3.8 3.8 0 0 0 3.8 3.8h4.4a3.8 3.8 0 0 0 3.8-3.8V7.4M12 16.6v-3.4"/>', s),
  external: (s?: number) =>
    svg('<path d="M14 4h6v6"/><path d="M20 4 11 13"/><path d="M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5"/>', s),
  arrowLeft: (s?: number) => svg('<path d="M19 12H5M11 6l-6 6 6 6"/>', s),
  arrowRight: (s?: number) => svg('<path d="M5 12h14M13 6l6 6-6 6"/>', s),
  globe: (s?: number) =>
    svg('<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c2.6 2.7 3.9 5.7 3.9 9s-1.3 6.3-3.9 9c-2.6-2.7-3.9-5.7-3.9-9S9.4 5.7 12 3z"/>', s),
  paperclip: (s?: number) => svg('<path d="M20 11.5 12 19.5a5 5 0 0 1-7-7l8.5-8.5a3.5 3.5 0 0 1 5 5L10 17.5a2 2 0 0 1-3-3l7.5-7.5"/>', s),
  // Iconos por tipo de archivo para el explorador. Se distinguen por FORMA, no
  // solo por color: un icono que solo cambia de tono no ayuda a quien no
  // distingue bien los colores, y el arbol se lee de un vistazo.
  fileCode: (s?: number) =>
    svg('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="m10.5 12-1.5 1.5 1.5 1.5M13.5 12l1.5 1.5-1.5 1.5"/>', s),
  fileDoc: (s?: number) =>
    svg('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M8.5 13h7M8.5 16h4"/>', s),
  fileData: (s?: number) =>
    svg('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M9 12.5c-1 0-1 3 0 3M15 12.5c1 0 1 3 0 3"/>', s),
  fileImage: (s?: number) =>
    svg('<rect x="4" y="4" width="16" height="16" rx="2"/><circle cx="9" cy="9.5" r="1.4"/><path d="m5 17 4-4 3.5 3.5L15.5 13l3.5 4"/>', s),
  fileConfig: (s?: number) =>
    svg('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><circle cx="12" cy="14" r="2"/><path d="M12 11v-1M12 18v-1M9.4 12.5l-.9-.5M15.5 15.5l-.9-.5"/>', s),
  fileArchive: (s?: number) =>
    svg('<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/><path d="M10.5 6.5h1M10.5 9h1M10.5 11.5h1M10.5 14h1"/>', s),
  folderOpen: (s?: number) =>
    svg('<path d="M3 7a2 2 0 0 1 2-2h4l2 2.5h8a2 2 0 0 1 2 2V18a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><path d="M3 11h18"/>', s),
  // archivo de sesiones. La caja con su ranura se lee como
  // «guardar sin borrar»; la flecha hacia arriba, como «recuperar».
  archive: (s?: number) =>
    svg('<rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>', s),
  unarchive: (s?: number) =>
    svg('<rect x="3" y="4" width="18" height="4" rx="1"/><path d="M5 8v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8"/><path d="M12 17v-5M9.5 14.5 12 12l2.5 2.5"/>', s),
  // menú de la fila de herramientas del panel derecho.
  menu: (s?: number) => svg('<path d="M4 6h16M4 12h16M4 18h16"/>', s),
};

export type IconName = keyof typeof icons;
