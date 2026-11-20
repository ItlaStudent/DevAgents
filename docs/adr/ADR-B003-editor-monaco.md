# ADR-B003 — Editor de código: Monaco vendorizado

**Estado**: Aceptada · **Fecha**: 2026-07-30 · **Decide**: usuario
**Depende de**: ADR-B002 · **Supersede**: ADR-002 heredado (Scintilla embebido con wrapper Qt)

## Contexto

El editor es el corazón de un IDE y lo más caro de construir bien. Se necesita: resaltado de sintaxis
multi-lenguaje, folding, multi-cursor, minimap, buscar/reemplazar, autocompletado, diff viewer y
decoraciones para marcar los cambios del agente.

El ADR-002 del proyecto padre eligió **Scintilla** con wrapper Qt propio, en el contexto de una cabina
Qt. Ese contexto ya no existe (ADR-B002).

## Decisión

Se usa **Monaco Editor** (MIT), **vendorizado** en el repositorio bajo
`shell/webui/vendor/monaco/`, con versión fija.

Monaco es literalmente el editor que VS Code usa por dentro, publicado como librería independiente
bajo licencia MIT. Usarlo **no** reintroduce ninguna dependencia de VS Code: es una librería de
edición de texto, no el IDE ni su API de extensiones.

Es la materialización de *"quedarse con lo bueno de VS Code sin el fork"*.

### Condiciones de la decisión

1. **Vendorizado, no CDN.** Copia del build en el repo, versión fija, sin descarga en runtime, sin
   servicio remoto. Coherente con el Principio IX.
2. **Sin dependencia de la API `vscode`.** Se usa el paquete standalone; se prohíbe cualquier shim
   que emule `vscode.*`.
3. **Presupuestos medidos** (gate G2): abrir archivo de 10 000 líneas ≤ 300 ms; scroll ≥ 50 fps;
   búsqueda global en 5 000 archivos ≤ 2 s.
4. **Ruta de escape definida**: si los presupuestos se incumplen de forma medida y no se pueden
   corregir con configuración, se abre ADR de migración del editor a Scintilla nativo compuesto junto
   al WebView, **sin** cambiar el resto de la cabina. La decisión se toma con números, no con
   corazonadas.

## Qué se obtiene de fábrica

Resaltado de 90+ lenguajes · folding · multi-cursor y selección por columnas · minimap ·
buscar/reemplazar con regex · **diff editor** side-by-side e inline · decoraciones y glyph margin
(base para marcar los hunks del agente) · cliente LSP para autocompletado y diagnósticos · atajos
familiares para cualquiera que venga de VS Code.

Los últimos dos puntos importan comercialmente: el usuario que llega de VS Code, Cursor o Windsurf
encuentra el editor que ya conoce.

## Alternativas consideradas

| Alternativa | Por qué no |
|---|---|
| **Scintilla nativo** (ADR-002 heredado) | Más ligero y más "puro", pero exige componer una ventana nativa junto al WebView (complejidad real de layout, foco y z-order), **y construir a mano** el diff viewer, el cliente LSP y el minimap que Monaco regala. Se conserva como plan B con criterio objetivo. |
| **CodeMirror 6** | Excelente y más ligero, pero su diff viewer y su ecosistema LSP son menos maduros; y no da la familiaridad de atajos que Monaco hereda de VS Code. |
| **Editor propio** | Injustificable. Meses de trabajo para igualar algo que existe bajo MIT. |

## Consecuencias

**Positivas**
- Se absorbe el mayor valor real que daba el fork sin arrastrar el fork.
- El código de diff ya escrito en TS (`DiffDecorator.ts`, `reviewChanges.ts`) se porta casi directo.
- Curva de aprendizaje nula para el usuario objetivo.

**Negativas, aceptadas**
- Monaco pesa ~5 MB minificado dentro del bundle. Encaja en el presupuesto de 40 MB.
- Es JavaScript ejecutándose en el WebView. Contenido: el JS no tiene acceso al FS ni a procesos;
  toda operación de archivo pasa por el puente validado hacia el host C++.
- Hay que mantener la versión vendorizada al día manualmente (tarea de F9 y de mantenimiento).

## Verificación (gate G2)

- Abrir un archivo real de 10 000 líneas, medido 5 veces, p50 y p95 reportados.
- Editar y guardar; verificar por `Get-FileHash` antes y después.
- Diff de un cambio real del agente: aceptar un hunk, rechazar otro, verificar el resultado en disco.
- Scroll continuo con muestreo de `requestAnimationFrame`.
