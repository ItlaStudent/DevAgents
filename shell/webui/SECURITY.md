# WebUI — seguridad del puente, lote 1

CSP: `script-src` sólo permite archivos del origen; no hay scripts inline propios que migrar. `style-src` conserva `'unsafe-inline'` porque Monaco/xterm crean estilos dinámicos, la cabina usa 745 atributos style en sus plantillas y hay dos `<style>` propios (detalle y plan para quitarlo en «Inventario residual»). Esto no habilita scripts ni eventos inline. Además `base-uri 'none'` y `form-action 'none'` impiden reescribir la base de URLs y enviar formularios fuera de los manejadores propios.

`src/design/html.ts` es el único escape de HTML: texto y atributos **entre comillas**, incluyendo `& < > " ' backtick`. No es escape para JS/CSS ni autorización de URLs. Los enlaces PR guardan la URL como dato escapado y su clic llama al host `shell.open`; el host valida el esquema. Issues y resultados MCP ya usan textContent. Se retiraron 14 implementaciones duplicadas, incluida `SpacesPanel.esc`.

Markdown conserva delimitadores en texto y escapa cada hoja antes de emitir etiquetas propias. Highlight tokeniza antes del escape para no romper entidades o alineación con textarea. Se corrigieron sinks adicionales en paleta, plan editable, ledger, metadatos de búsqueda y editor; feedback MCP/terminal usan textContent.

Guardar como: `dialog.saveAs` emite ruta/token, consumido en un único `doc.save`; cancelar/fallar conserva el borrador. El fallo estable `Save path not authorized` abre ese diálogo. Si cambia la ruta se abre la copia en una nueva pestaña y se conserva el borrador original. `dialog.pickWorkspace` autoriza una raíz por gesto nativo; `dialog.pickFolder` es selector genérico y no autoriza escritura.

## Inventario residual (, 19-oct)

Recuento medido con el script del informe de sobre `shell/webui/src` (asignaciones `.innerHTML =`, `.outerHTML =` e `insertAdjacentHTML(`; se descartan comentarios): **137 al inicio de esta vuelta** (la cifra de 114 de la versión anterior estaba desfasada) y **121 ahora**. La diferencia son 16 asignaciones con datos variables que pasan a `setHtml` (`html.ts:54`, única asignación de las plantillas seguras). No existen `outerHTML =`, `document.write` ni `srcdoc` en el código propio (`outerHTML` en `preview_elements.ts` es un campo de datos que se cita como texto).

Helpers nuevos en `src/design/html.ts`: la plantilla etiquetada `html` escapa por defecto cada interpolación (olvidar el escape deja de ser posible), `raw` marca marcado fijo del propio código (iconos SVG, literales; nunca datos), `joinHtml` concatena listas y `setHtml(el, safe)` asigna. `escapeText`/`escapeAttribute` siguen siendo el escape de bajo nivel.

Origen de los datos: **C** constante o marcado fijo del código · **U** dato del usuario (nombres de archivo, búsqueda, texto escrito) · **M** dato del modelo · **E** dato del motor/host (IPC: catálogos, sesiones, eventos, estado). Estado: **MIG** migrado en esta vuelta a `html.ts` · **SEG** ya seguro y justificado (cada dato variable pasa por `escapeText`/`escapeAttribute`; el resto es marcado fijo) · **PEND** pendiente para otra vuelta (archivo fuera del alcance de esta).

| Archivo | Asignaciones y líneas | Origen | Estado |
| --- | --- | --- | --- |
| `src/app/view_router.ts` | 52: 190, 265, 273, 286, 289, 297, 303, 324, 328, 334, 341, 376, 394, 432, 435, 547, 581, 619, 652, 687, 756, 771, 818, 993, 1179, 1185, 1192, 1201, 1426, 1427, 1439, 1440, 1447, 1448, 1453, 1530, 1536, 1545, 1549, 1569, 1586, 1598, 1625, 1628, 1644, 1652, 1655, 1673, 1681, 1702, 1709, 1728 | C estructura e iconos; U nombres de archivo, búsqueda; E sesiones, errores, MCP, estado del motor | MIG: fila de sesión (`sessRowHtml`), `line()`, filas de problemas (3), árbol de archivos, herramientas MCP y navegación de Ajustes. SEG: el resto (datos por `esc`/`escapeAttribute`). **r2:** `paintEngineOutput` ya no inserta HTML ajeno por `innerHTML`: renderiza con `setHtml`/`html` y la `traza` llega como `SafeHtml` que construye `mission_control.ts` con las plantillas (escape por defecto); el sumidero la coacciona con `asSafeHtml`, que escapa cualquier valor que no sea `SafeHtml`, así que no depende del contrato manual del productor |
| `src/browser/browser_bar.ts` | 3: 60, 329, 390 (más 9 migradas) | C esqueleto; E pestañas, URL, origen, errores y bloqueos del host (datos de la página) | MIG: pestañas, origen, botón de control, recarga y las cuatro tarjetas (`data-tab`, `data-close`, `data-trust` ya se escapan: antes iban sin escapar). Las 3 restantes: SEG (esqueleto fijo, vaciado y diálogo con `textContent` para origen y fuente) |
| `src/panes/settings_memory.ts` | 6: 301, 310, 346, 401, 1119, 1140 | C estructura; E proveedores, claves, modelos, memoria, errores | SEG: los datos pasan por `esc`/`escapeAttribute` (esta vuelta: `data-settings-section` y los contadores del catálogo). 401 es `insertAdjacentHTML` de `icons.layers(22)`, constante. Migración completa a la plantilla `html` de los ~140 estilos y bloques: PEND |
| `src/panes/verification_panel.ts` | 1: 40 | C estructura | MIG: verificaciones y ledger (E). La que queda es plantilla fija |
| `src/panes/catalog_sessions.ts` | 1: 48 | C estructura | MIG: catálogo y sesiones (E). Antes `contextWindow.toLocaleString()` salía sin escapar |
| `src/layout/layout.ts` | 3: 61, 276, 284 | C plantilla, catálogo de vistas e iconos | SEG: marcado fijo; `data-view`/`id`/`title` de las vistas se escapan ahora aunque sean constantes |
| `src/components/timeline.ts` | 2: 137, 171 | C; E eventos del motor | MIG: la fila (`paintRow`). Las 2 restantes: marcado fijo y vaciado |
| `src/components/command_palette.ts` | 2: 43, 133 | C; categorías, etiquetas y atajos de comandos propios | MIG: la lista de comandos. Las 2 restantes: plantilla fija y mensaje fijo |
| `src/terminal/xterm_terminal.ts` | 2: 372, 501 | C plantilla; E salida del terminal (ANSI) | SEG: 372 plantilla fija con iconos; 501 recibe `ansiToHtml`, que escapa el texto y genera colores solo desde números parseados y tablas propias |
| `src/panes/monitor_panel.ts` | 2: 184, 193 | C; E estado, sesiones, aprobaciones, salud, ledger | MIG: filas de sesiones, aprobaciones y especialistas. SEG: el resto, con `esc` en cada dato; la cáscara es fija |
| `src/panes/mission_control.ts` | 11: 484, 864, 1094, 1166, 1326, 1635, 2223, 2309, 2322, 2435, 5009 | C; U; M; E | PEND (fuera de alcance de esta vuelta); SEG según el inventario anterior |
| `src/panes/right_cards.ts` | 10: 408, 457, 499, 583, 633, 644, 727, 746, 811, 977 | C; E (rama, archivos, cambios, tareas) | PEND (otra rama lo toca hoy) |
| `src/panes/chat_panel.ts` | 9: 304, 327, 399, 421, 527, 531, 540, 600, 640 | C; M texto del modelo; E | PEND |
| `src/editor/diff_viewer.ts` | 4: 367, 383, 398, 431 | U/E contenido y rutas de archivos | PEND |
| `src/editor/monaco_editor.ts` | 3: 295, 384, 892 | U contenido del archivo (resaltado escapado por token) | PEND |
| `src/components/conversation_control.ts` | 1: 77 | C; E planes | PEND (SEG según inventario anterior) |
| `src/components/copy_image_menu.ts` | 1: 22 | C | SEG: dos botones con literales |
| `src/components/onboarding_help.ts` | 2: 31, 129 | C | SEG: pasos y ayuda escritos en código |
| `src/layout/tab_manager.ts` | 2: 145, 162 | U/E títulos de pestaña (escapados) | PEND (SEG según inventario anterior) |
| `src/panes/SpacesPanel.ts` | 1: 97 | E nombres, rutas, configuración | PEND (SEG según inventario anterior) |
| `src/panes/issues_panel.ts` | 1: 10 | C | SEG: plantilla estática; los datos van por `textContent` |
| `src/panes/mcp_panel.ts` | 1: 69 | E herramientas MCP | PEND (SEG según inventario anterior) |
| `src/design/html.ts` | 1: 54 | helper | `setHtml`, única asignación de las plantillas etiquetadas `html` |

Totales: 121 = 74 en los diez archivos del alcance (52 + 3 + 6 + 1 + 1 + 3 + 2 + 2 + 2 + 2) + 37 en archivos excluidos de esta vuelta (11 + 10 + 9 + 4 + 3) + 9 en otros archivos sin tocar (1 + 1 + 2 + 2 + 1 + 1 + 1) + 1 en el helper. Sin tocar en esta vuelta, y por tanto sin ser un inventario nuevo: `markdown.ts` (devuelve HTML escapado por dentro) y `notice.ts` (usa `textContent`).

### `style-src 'unsafe-inline'`: qué lo exige hoy y por qué sigue

No se quita en esta vuelta; hacerlo rompería la cabina. Lo exigen:

- **745 atributos `style="..."` en plantillas** de `src` (`mission_control.ts` 212, `settings_memory.ts` 143, `view_router.ts` 59, `monitor_panel.ts` 59, `chat_panel.ts` 49, `SpacesPanel.ts` 35, resto repartido). Los atributos de estilo en marcado insertado por `innerHTML` están bloqueados sin `'unsafe-inline'` (o `style-src-attr`). (Las asignaciones CSSOM `el.style.x = ...` y `style.cssText = ...` no necesitan `unsafe-inline`.)
- **Dos elementos `<style>` propios:** `public/index.html:32` (fondo inicial anti-destello) y `src/design/stylesheet.ts:1684` (`injectStylesheet()` crea un `<style>` con toda la hoja).
- **Monaco y xterm** crean elementos `<style>` en ejecución (`vendor/monaco/editor-KLE6jdfb.js`, `vendor/xterm/xterm.js`) y Monaco aplica estilos en línea para geometría y decoraciones.

Para quitarlo haría falta: (1) mover el `<style>` de `index.html` a un archivo y servir la hoja de `stylesheet.ts` como archivo del origen (o `adoptedStyleSheets`); (2) pasar los 745 `style="..."` a clases (o a asignaciones CSSOM tras insertar el DOM), con las plantillas etiquetadas `html` ya como punto único para hacerlo mecánicamente; (3) dar a Monaco/xterm un `nonce` por carga (el host debe inyectarlo en la meta CSP y en `index.html`) o, como paso intermedio, partir la política en `style-src-elem 'self' 'nonce-…'` y `style-src-attr 'unsafe-inline'`. Hasta entonces la política mantiene `script-src` sin inline, que es lo que impide ejecutar código.

Limitación: no se hizo una auditoría completa de coerción de todas las estadísticas numéricas IPC ni de cada interpolación CSS. ANSI genera colores desde números parseados y tablas propias; minimap usa geometría DOM. El inventario no declara una auditoría independiente y no garantiza invariantes de datos de futuras extensiones. La comprobación de origen no distingue scripts legítimos de un script que ya se ejecute dentro del origen: `pty.write` conserva una capacidad privilegiada residual de ejecución como el usuario, condicionada a JavaScript de confianza; no es un sandbox. `hunk.accept/reject` y `search.replace` comparten ahora la autorización de raíces y el escritor por handle de `doc.save`; el rootDir del reemplazo debe ser una raíz autorizada exacta. CSP y escape son necesarios; este lote no constituye un sandbox completo del puente.

Pruebas enfocadas: desde `shell/webui`, `npm run test:security` (node:test + esbuild ya instalado; sin paquetes nuevos). Tabla XSS en texto/atributos, Markdown, siete lenguajes de highlight, ANSI, paleta/ledger/plan y Guardar como (cancelación/éxito/fallo), CSP y ausencia de escapes duplicados. Build: `npm run build`. La evidencia E2E de cabina vive con las pruebas CDP del lote.
