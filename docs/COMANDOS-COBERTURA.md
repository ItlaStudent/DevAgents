# Cobertura CLI de DevAgents

**Corte:** 12-oct-2026. **Alcance:** comandos anunciados por el CLI actual; esta lista no mide cobertura de UI ni paridad MCP.

**Evidencia directa:** ejecutar zig-out/bin/devagents-core.exe --help en este árbol devolvió el bloque de ayuda completo con EXIT 0. Las formas de abajo reproducen esa salida; consulta --help para opciones adicionales.

| Comando | Formas anunciadas por el CLI |
|---|---|
| models | list |
| chat | --model <id> [--provider <nombre>] [--prompt <texto>\|--stdin] |
| route | --demo |
| agents | [list] |
| mount | add\|remove\|list <ruta> |
| webhook | add --url <url> [--event <ev>]; remove <id>; list |
| health | [list] [--json]; probe --provider <p> --model <m> |
| debug | last [--full]; <order_id> [--full]; --on\|--off; --status |
| order | "<texto>" [--yes] [--sudo] |
| governance | [free\|paid\|hybrid] |
| selftest | [--caso <nombre>] |
| design | [--stdin] [--project-dir <dir>] |
| usage | sin argumentos |
| server | [--pipe <nombre>] |
| remote | serve --data-dir <dir> [--port <n>] [--origin <url>] |

Esta matriz reemplaza la matriz archivada del 2-ago que contaba métodos de UI antiguos y afirmaba 0 cubiertos, 37 parciales y 17 sin cobertura. No infiere que un comando esté expuesto en la cabina. Para estado actual del producto, usa la documentación interna y el registro append-only de auditorías.
