# ADR-B008 — Nombre comercial del producto: DevAgents

**Estado**: Aceptada · **Fecha**: 2026-08-02 · **Decide**: usuario (propietario del proyecto)
**Referencia**: ADR-B001, ADR-B004-B007, Constitución v4.0.0

## Contexto

Durante el proceso de refundación e independización de la arquitectura (ADR-B001), se utilizó de forma provisional la denominación "DevAgents" en nombres de binarios, exportaciones, variables de entorno, esquema de URLs y marcas visibles en la interfaz de usuario, con el propósito de diferenciar este repositorio del proyecto original durante la coexistencia de ambos.

Decisión firme del propietario del proyecto (2026-08-02): El nombre comercial y público del producto es **DevAgents**. La denominación "DevAgents" se conserva **únicamente** como el nombre del directorio local del repositorio (`Proyecto - DevAgents`) mientras coexista con la carpeta del fork antiguo.

Esta decisión revierte el renombrado de superficie pública realizado previamente en F0-T3 y restaura la marca única DevAgents en toda la superficie expuesta a usuarios e integradores.

## Decisión

1. **Nombre del Producto**: El producto se denomina exclusivamente **DevAgents** en toda interfaz gráfica, mensajes CLI, títulos de ventana, protocolos MCP, logs y comunicaciones públicas.
2. **Binarios y Bibliotecas**:
 - `beats-core` -> `devagents-core`
 - `beats-mcp` -> `devagents-mcp`
 - `beats_core.dll` -> `devagents_core.dll`
 - `beats-host` -> `devagents-host`
 - `beats-demo` -> `devagents-demo`
3. **Comandos de CLI**:
 - `devagents <verbo>` pasa a `devagents <verbo>`.
4. **Variables de Entorno**:
   - Variables primarias: `DEVAGENTS_DATA_DIR`, `DEVAGENTS_MODEL_CALL_TIMEOUT_MS`, `DEVAGENTS_DEVTOOLS_PORT`, `DEVAGENTS_PERF_LOG`.
 - Compatibilidad / Aliases leídos: Para evitar romper scripts de entorno existentes, las variables con prefijo `BEATS_` (`BEATS_DATA_DIR`, etc.) se mantienen como alias leídos de respaldo si la variable primaria con prefijo `DEVAGENTS_` no está definida.
5. **Exports C-ABI**:
 - `beats_core_init` y `beats_core_shutdown` pasan a `da_core_init` y `da_core_shutdown` respetando el prefijo `da_` del C-ABI de 74 funciones.
6. **Host Virtual WebView2**:
 - `devagents.local` -> `devagents.local`.
7. **Prefijos de Log y UI**:
 - `[BEATS_*]` -> `[DEVAGENTS_*]`.
   - Títulos UI y `<title>`: "DevAgents".

## Lo que NO cambia

- El nombre de la carpeta raíz del repositorio (`Proyecto - DevAgents`).
- Archivos históricos, evidencias de auditoría y ADRs previamente redactados (ADR-B001..B007).
- Funciones C-ABI con prefijo `da_*` ya existentes.
- Directorio de caché de desarrollo (`C:\tmp\beats-cache`).

## Consecuencias

- Coherencia total de marca frente al usuario final e integradores MCP.
- Transición suave para herramientas que lean variables de entorno antiguas mediante el soporte de alias leídos.
