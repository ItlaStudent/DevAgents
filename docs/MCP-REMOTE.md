# DevAgents MCP — Guía de Integración para IDEs Externos

Servidor MCP (Model Context Protocol) sobre stdio que expone el núcleo
DevAgents a cualquier IDE o agente compatible (Claude Code, Cursor, Codex,
Zed, Opencode, etc.).

**Corte documental: 12-oct-2026.** El catálogo estático actual contiene 108 nombres únicos (`tools/mcp_server.zig:1420-1529`; la prueba del catálogo espera 108 en `:3205-3211`). Las menciones a 106 se conservan como medición histórica de E5.26/E5.27 del 2-oct (`la documentación interna:1019`). La tabla de este documento sigue siendo parcial; `tools/list` entrega el catálogo vivo.

## Token de autenticación y logs

Con `DEVAGENTS_MCP_TOKEN`, el lanzador entrega el token y la sesión nace
autenticada. Sin esa variable, el servidor lee `mcp_token` junto a la base;
el cliente presenta ese token en `initialize.params.token` o `authenticate`.
El servidor nunca imprime un token suministrado por entorno o archivo.

Si no existe ninguno, genera uno nuevo y lo informa una sola vez por stderr
para que el operador pueda autenticarse. El aviso distingue «generado y
persistido», «no persistido» y «efimero» (por ejemplo, con `--db :memory:`).
Ese aviso deliberado contiene la credencial del proceso: al capturar evidencia,
censurar el valor de cualquier mensaje `token de autenticacion (...)` antes
de escribirlo. Los productores B7 usan `tools/e5_b7_redact.ps1` o
`tools/e5_b7_redact.py`; `tools/e5_b7_token_notice.py` prueba las cinco ramas
contra el binario real con datos sintéticos y limpia sus temporales.

## Quick start

### 1. Compilar

```bash
zig build install -j1
```

Genera `zig-out/bin/devagents-mcp.exe` (Windows). La edición original también describía `zig-out/bin/devagents-mcp` para Linux; esa salida queda como referencia histórica y B10 sigue sin integrarse en `main` (`la documentación interna:59`).

Para deploy al build optimizado (la referencia al “fork” es histórica, 2026-07-30):

```bash
zig build install -Doptimize=ReleaseFast -j1
```

El binario resultaba en ~3.3-3.6 MB (medición histórica de 2026-07-30; tamaño actual no medido aquí).

### 2. Lanzar el servidor

```bash
# Básico — usa runtime.db del directorio actual
devagents-mcp.exe

# Con data-dir explícito (recomendado para IDEs externos)
devagents-mcp.exe --data-dir C:\path\to\engine\data

# Con variable de entorno
set DEVAGENTS_DATA_DIR=C:\path\to\data
devagents-mcp.exe

# Con db path explícito (avanzado)
devagents-mcp.exe --db C:\path\to\runtime.db
```

**Prioridad de resolución del data directory (orden único,):**
1. `--data-dir <ruta>` (flag de línea de comandos)
2. `BEATS_DATA_DIR` (variable de entorno; debe ser ruta absoluta con unidad y existente, si no: fallo cerrado con mensaje, nunca una base relativa ni la real)
3. `DEVAGENTS_DATA_DIR` (alias de `BEATS_DATA_DIR`, compatibilidad; mismas reglas)
4. Por defecto: `%LOCALAPPDATA%\DevAgents`, resuelto con la API de carpetas conocidas (la misma carpeta que usa la cabina; no la variable `LOCALAPPDATA`)

Si ambas variables están definidas, gana `BEATS_DATA_DIR` (el alias solo se consulta si aquella no está). Antes de esta regla era al revés en el MCP. Los despliegues fijan como mínimo `BEATS_DATA_DIR` (p. ej. `tools/suite_native_fixture.py`) o ambas al mismo valor precreado (`tools/e5_b9_verify.ps1`, `tools/e5_loc_*.ps1`, `tools/ordenes_*.ps1`, `tools/e5_loc_health.py`): ninguno depende de que el servidor cree la carpeta.

La resolución vive en una sola función, `core.paths.resolveDataDir` (`core/src/paths.zig`), que comparten la CLI, el núcleo y el MCP; la cabina replica exactamente el mismo orden en `shell/host/core_client.cpp`. La tool `capabilities` y `devagents-core --version` informan la carpeta real que se abrió (ya no «(cwd default)»). Si la API de carpetas conocidas falla, la resolución falla cerrado (`DefaultDataDirUnavailable`): no hay resolución heredada, nunca se cae a una base relativa al directorio de trabajo ni a la real sin la protección DACL.

**Modo aislado para pruebas:** fija `BEATS_DATA_DIR` a una carpeta temporal propia *dentro del proceso de prueba* —es lo que hace el fixture `tools/suite_native_fixture.py` para toda la suite—; así las pruebas crean sus bases en esa carpeta temporal y ninguna toca la real del usuario.

Cuando se usa `--data-dir`, el servidor busca `<data-dir>/runtime.db` y
`<data-dir>/catalog.db`. Si `runtime.db` no existe, cae a `:memory:`.

El ejemplo sin `--data-dir` describe el comportamiento de la edición original. Para operar con los datos de la cabina actual, no se debe asumir un `runtime.db` junto al proyecto: la carpeta por defecto es `%LOCALAPPDATA%\DevAgents` (orden y detalle arriba); para un cliente externo, configura de forma explícita el directorio que corresponda. Fuentes: `shell/host/core_client.cpp` (UserDataDir); `core/src/paths.zig` (resolveDataDir).

### 3. Configurar en tu IDE

#### Claude Code

```json
{
  "mcpServers": {
    "devagents": {
      "command": "C:\\path\\to\\devagents-mcp.exe",
      "args": ["--data-dir", "C:\\path\\to\\engine\\data"],
      "cwd": "C:\\path\\to\\project"
    }
  }
}
```

#### Cursor

```json
{
  "mcpServers": [
    {
      "name": "devagents",
      "command": "C:\\path\\to\\devagents-mcp.exe",
      "args": ["--data-dir", "C:\\path\\to\\engine\\data"]
    }
  ]
}
```

#### Configuración genérica (cualquier cliente MCP)

```json
{
  "mcpServers": {
    "devagents": {
      "command": "/path/to/devagents-mcp",
      "args": ["--data-dir", "/path/to/engine/data"]
    }
  }
}
```

## Protocolo

- **Transporte**: stdio (JSON-RPC 2.0 line-delimited)
- **Handshake**: cliente envía `initialize` → servidor responde con `protocolVersion: 2024-11-05`
- **Notificación**: `notifications/initialized` (sin respuesta)
- **Discovery**: `tools/list` devuelve las herramientas con sus JSON Schemas
- **Ejecución**: `tools/call` con `name` + `arguments`

### Handshake

```json
→ {"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
← {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"devagents-mcp","version":"0.1.0"}}}
```

Desde el 10-nov-2026 `initialize` declara `devagents-mcp`, igual que el ejecutable `devagents-mcp.exe` (antes declaraba `beats-mcp`).

```json
→ {"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
```

(No hay respuesta a la notificación.)

## Tool: `capabilities` (punto de entrada)

**Recomendado como primera llamada** para cualquier IDE que se conecta.
Devuelve metadatos del motor: versión, lista de tools, rutas de datos,
y proveedores configurados (solo nombres y si tienen clave activa,
**NUNCA valores de claves**).

```json
→ {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capabilities","arguments":{}}}
```

Respuesta (dentro de `content[0].text`):

```json
{
  "ok": true,
  "version": "0.1.0",
  "protocolVersion": "2024-11-05",
  "dataDir": "C:\\path\\to\\engine\\data",
  "catalog": {
    "catalog_path_abs": "C:\\path\\to\\catalog.db",
    "model_count": 42,
    "provider_count": 5,
    "key_count": 3
  },
  "providers": [
    {"provider": "OpenRouter", "has_key": true},
    {"provider": "NVIDIA API", "has_key": true}
  ],
  "tools": ["health", "health_probe_all", "health_summary", "capabilities", "sessions", ...]
}
```

Los valores de catálogo y proveedores de este bloque son un ejemplo de forma JSON, no datos medidos ni una muestra de la base del usuario. El conteo vigente de herramientas es 108 (`tools/mcp_server.zig:1420-1529,3205`).

## Catálogo de Tools (106 herramientas; tabla de referencia parcial)

**Histórico (2-oct-2026):** 106 herramientas únicas en E5.26/E5.27 (`la documentación interna:1019`). **Hoy, 12-oct-2026:** 108 nombres únicos en el arreglo de capacidades, sin duplicados; la prueba fuente fija `tools.len == 108` (`tools/mcp_server.zig:1420-1529,3205`). Se conserva el valor histórico para que el cambio de catálogo sea trazable.

El catálogo completo y vigente se obtiene con `tools/list`; `capabilities.tools`
contiene los mismos nombres únicos que el servidor anuncia al cliente. Incluye incidencias B8,
webhooks/remoto B9 y configuración de agentes externos B13.

### Lectura (read-only)

| Tool | Descripción | Args |
|---|---|---|
| `capabilities` | Metadatos del motor (versión, tools, rutas, proveedores) | — |
| `health` | Salud detallada por (proveedor, modelo) | — |
| `health_summary` | Resumen de salud por proveedor | — |
| `health_probe_all` | Sonda activa de todos los modelos | `max_models?: int` |
| `catalog_info` | Info del catálogo: ruta, conteos | — |
| `models_list` | Lista de modelos registrados | — |
| `router_candidates` | Candidatos del router para una tarea | `task_type: string` |
| `sessions` | Órdenes/sesiones activas con estado | — |
| `session_messages` | Mensajes de una sesión | `order_id: int` |
| `session_timeline` | Timeline completo (mensajes + eventos) | `order_id: int, offset?: int, limit?: int` |
| `order_status` | Estado numérico + texto de una orden | `order_id: int` |
| `order_events` | Timeline de eventos (polling incremental) | `order_id: int, since_event_id?: int` |
| `get_plan` | Plan de la orden (entendimiento + tasks) | `order_id: int` |
| `approvals_list` | Aprobaciones pendientes | — |
| `worker_output` | Salida de workers por polling | `since_ms: int` |
| `list_artifacts` | Archivos generados por orden | `order_id?: int` |
| `ledger_escalations` | Filas ESCALATION del ledger | — |
| `audit_ledger` | Todas las acciones del audit ledger | — |
| `memory_context` | Contexto de memoria para un proyecto | `project: string` |
| `usage_summary` | Resumen de uso de tokens | `order_id?: int` |
| `specialists` | Registro de especialistas y divisiones | — |
| `skills_discover` | Inventario de skills desde mounts | — |
| `mounts_list` | Mounts registrados | — |
| `mcp_is_connected` | Estado de conexión MCP externo | — |
| `mcp_tools` | Tools del servidor MCP externo | — |
| `plan_get_model` | Modelo forzado para planificación | — |
| `list_keys` | Claves registradas (sin secreto) | — |

### Acción (mutan estado o ejecutan)

| Tool | Descripción | Args |
|---|---|---|
| `da_submit_order` | Envía orden en lenguaje natural | `order_text: string, project_id?: string` |
| `da_submit_order_async` | Envía orden asíncrona (no bloquea) | `order_text: string, project_id?: string` |
| `plan_poll` | Consulta si planificación async terminó | — |
| `answer_order` | Responde preguntas de clarificación | `order_id: int, answers_json: string` |
| `confirm_plan` | Guarda/reemplaza el plan; no despacha ni es aprobación humana | `order_id: int, plan_json?: string` |
| `dispatch_async` | Despacha orden planeada en background; los comandos no-consulta y los agentes externos requieren la cabina | `order_id: int` |
| `dispatch_poll` | Consulta si despacho async terminó | `order_id: int` |
| `plan_approve` · `plan_replan` · `session_archive` · `spaces_list` | T7: aprobar (igual que el botón de la cabina) y replanificar el plan, archivar una sesión, listar spaces | ver `docs/MCP-SURFACE-MAP.md` |
| `fs_list` · `fs_read` · `fs_search` · `fs_write` | T7: archivos con las tools confinadas del agente (raíz del proyecto o `space_id`) | `path`, `space_id?`, `project_id?` |
| `git_status` · `git_diff` · `git_log` · `git_add` · `git_commit` | T7: git domesticado de la cabina por la puerta de `shell_run` (tarjeta en la cabina); sin push | ver `docs/MCP-SURFACE-MAP.md` |
| Permisos, aprobaciones de comandos, límites, rutas de CLIs, iteraciones, cupo, hooks, plugins, `mcp_connect` | **SOLO CABINA** (T7, «paridad sin gobierno»): no se anuncian y responden error sin tocar el motor | — |
| `shell_run` | Ejecuta comando gobernado (sandbox) | `exe: string, args?: array, cwd?: string, timeout_ms?: int` |
| `run_detached` | Lanza proceso detached (GUI) | `exe: string, args?: array, cwd?: string` |
| `discover_models` | Descubrimiento vivo de modelos | — |
| `plan_set_model` | Fija modelo forzado para planificación | `provider?: string, model?: string` |
| `add_key` | Añade clave API cifrada (DPAPI) | `provider: string, label: string, key: string` |
| `remove_key` | Elimina clave por etiqueta | `provider: string, label: string` |
| `set_workspace_root` | Estrecha la raíz a una subcarpeta de la actual (moverla requiere la cabina o `DEVAGENTS_WORKSPACE_ROOT` al lanzar) | `path: string` |
| `mount_add` | Agrega ruta de mounts | `path: string` |
| `mount_remove` | Elimina mount | `path: string` |
| `mcp_disconnect` | Desconecta MCP externo | — |
| `mcp_call_tool` | Llama tool del MCP externo | `name: string, args_json: string` |
| `session_rename` | Renombra una sesión | `order_id: int, title: string` |
| `screenshot` | Captura de pantalla PNG | — |
| `preview` | Vista previa embebida de URL | `url: string` |
| `web_search` | Búsqueda web (DuckDuckGo/Tavily/Brave) | `query: string, max_results?: int` |

## Flujos completos

### Flujo 1: Orden E2E — submit → plan_poll → confirm_plan → dispatch_async → dispatch_poll → list_artifacts

```
Cliente                                          Servidor
  │                                                │
  │── initialize ─────────────────────────────────→│
  │←─ protocolVersion 2024-11-05 ─────────────────│
  │                                                │
  │── da_submit_order_async ──────────────────────→│
  │←─ {"order_id": 1} ────────────────────────────│
  │                                                │
  │── plan_poll (repetir cada 500ms) ─────────────→│
  │←─ {"done": 0} ────────────────────────────────│
  │── plan_poll ──────────────────────────────────→│
  │←─ {"done": 1, "ok": 1} ───────────────────────│
  │                                                │
  │── get_plan ───────────────────────────────────→│
  │←─ {"understanding":"...","tasks":[...]} ──────│
  │                                                │
  │── confirm_plan ───────────────────────────────→│
  │←─ {"ok": true} ───────────────────────────────│
  │                                                │
  │── dispatch_async ─────────────────────────────→│
  │←─ {"ok": true} ───────────────────────────────│
  │                                                │
  │── dispatch_poll (repetir cada 1s) ────────────→│
  │←─ {"done": 0} ────────────────────────────────│
  │── dispatch_poll ──────────────────────────────→│
  │←─ {"done": 1, "ok": 1} ───────────────────────│
  │                                                │
  │── order_events (since_event_id=0) ────────────→│
  │←─ [{id:1,...},{id:2,...},...] ────────────────│
  │                                                │
  │── list_artifacts (order_id=1) ────────────────→│
  │←─ [{"file_path":"main.py","size":1234},...] ──│
```

**Ejemplo request/response:**

```json
→ {"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"da_submit_order_async","arguments":{"order_text":"haz una calculadora CLI en C con tests","project_id":"demo"}}}
← {"jsonrpc":"2.0","id":10,"result":{"content":[{"type":"text","text":"{\"order_id\":1}"}]}}

→ {"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"plan_poll","arguments":{}}}
← {"jsonrpc":"2.0","id":11,"result":{"content":[{"type":"text","text":"{\"done\":0}"}]}}

→ {"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_plan","arguments":{"order_id":1}}}
← {"jsonrpc":"2.0","id":12,"result":{"content":[{"type":"text","text":"{\"understanding\":\"Construir calculadora...\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar\",...}]}"}]}}

→ {"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"confirm_plan","arguments":{"order_id":1}}}
← {"jsonrpc":"2.0","id":13,"result":{"content":[{"type":"text","text":"{\"ok\":true}"}]}}

→ {"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"dispatch_async","arguments":{"order_id":1}}}
← {"jsonrpc":"2.0","id":14,"result":{"content":[{"type":"text","text":"{\"ok\":true}"}]}}

→ {"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"dispatch_poll","arguments":{"order_id":1}}}
← {"jsonrpc":"2.0","id":15,"result":{"content":[{"type":"text","text":"{\"done\":1,\"ok\":1}"}]}}

→ {"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"list_artifacts","arguments":{"order_id":1}}}
← {"jsonrpc":"2.0","id":16,"result":{"content":[{"type":"text","text":"[{\"file_path\":\"main.c\",\"size\":2048},{\"file_path\":\"test.c\",\"size\":1024}]"}]}}
```

`confirm_plan` solo guarda o reemplaza el plan. El despacho empieza con `dispatch_async`; después `dispatch_poll` consulta el resultado. Una orden iniciada por MCP no ejecuta comandos por sí sola: cada uno que no sea una consulta de versión acotada espera una tarjeta de aprobación en la cabina (véase SEC2-GOBERNANZA-MCP.md). `mcp_connect` no se ofrece por MCP. `remote_start` valida sus argumentos y responde con error: el acceso remoto se inicia desde la cabina, que es donde se muestra el token (un cliente MCP es un agente y no recibe esa credencial; integración de `e5-harden`, 13-nov-2026). Aun así, el núcleo de una sesión MCP responde 403 a todo POST remoto (aprobar, denegar, cancelar, restaurar permisos); `ui_action` exige la credencial; el cupo de pago (`paid_budget_set`) solo se cambia en la cabina desde T7.

### Flujo 2: Salud / Catálogo — capabilities → models_list → health_probe_all

```json
→ {"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"capabilities","arguments":{}}}
← {"jsonrpc":"2.0","id":20,"result":{"content":[{"type":"text","text":"{\"ok\":true,\"version\":\"0.1.0\",\"providers\":[...],\"tools\":[...]}"}]}}

→ {"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"models_list","arguments":{}}}
← {"jsonrpc":"2.0","id":21,"result":{"content":[{"type":"text","text":"[{\"provider\":\"openai\",\"model\":\"gpt-4o\",\"context\":128000,\"is_free\":false},...]"}]}}

→ {"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"health_probe_all","arguments":{"max_models":50}}}
← {"jsonrpc":"2.0","id":22,"result":{"content":[{"type":"text","text":"{\"candidates\":42,\"probed\":42,\"ok\":38,\"failed\":3,\"skipped\":1,\"disabled_not_found\":0}"}]}}
```

### Flujo 3: Sesiones — sessions → session_messages

```json
→ {"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"sessions","arguments":{}}}
← {"jsonrpc":"2.0","id":30,"result":{"content":[{"type":"text","text":"[{\"id\":1,\"title\":\"Calculadora CLI\",\"status\":5,\"status_text\":\"done\",\"created_at\":\"2026-07-04T12:00:00Z\"}]"}]}}

→ {"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"session_messages","arguments":{"order_id":1}}}
← {"jsonrpc":"2.0","id":31,"result":{"content":[{"type":"text","text":"[{\"id\":1,\"role\":\"user\",\"content\":\"haz una calculadora\",\"created_at\":\"...\"},{\"id\":2,\"role\":\"assistant\",\"content\":\"Entendido. Mi plan es...\",\"created_at\":\"...\"}]"}]}}
```

## Seguridad

- **Sin claves API expuestas**: ninguna tool devuelve texto de clave ni
  permite lectura directa de `catalog.db` / `runtime.db`. Las tools
  `add_key`, `remove_key`, `list_keys` gestionan claves pero `list_keys`
  solo devuelve `{provider, label, status}` — nunca el valor.
- **`capabilities`**: devuelve `has_key: true/false` por proveedor, nunca
  el valor de la clave.
- **`shell_run` delegado**: usa la misma ruta `da_shell_run` →
  `executor.runGoverned` con allowlist + sandbox de cwd + Job Object +
  timeout. El escáner de seguridad bloquea argumentos con `.db` u
  operaciones destructivas.
- **`confirm_plan` requiere estado planned**: si la orden no está en
  estado `planned`, devuelve error.
- **Origen untrusted**: `da_submit_order` con `project_id` remoto inserta
  aprobación pendiente (gate EXEC-02), requiriendo confirmación humana
  antes de despachar.

## Multi-cliente

El servidor MCP es **monohilo** y lee stdin línea por línea. No hay
estado compartido entre clientes. Cada instancia del servidor tiene su
propio `CoreState` y su propio `runtime.db`.

**Para multi-cliente simultáneo:**
- Lanzar una instancia del servidor por cliente (recomendado).
- Usar `--data-dir` para apuntar todas las instancias al mismo directorio
  de datos. SQLite maneja concurrencia con WAL mode.
- Si dos clientes envían órdenes simultáneamente, cada una obtiene su
  propio `order_id` sin colisión.

## Verificación manual

Desde PowerShell:

```powershell
$req = @'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capabilities","arguments":{}}}
'@
$req | .\zig-out\bin\devagents-mcp.exe --data-dir .\engine\data
```

Debe devolver:
1. Respuesta `initialize` con `protocolVersion: 2024-11-05`.
2. Array de tools con schemas: 106 fue el conteo histórico tras integrar B8, B9 y B13 (2-oct); el código actual contiene 108 nombres únicos al 12-oct (`tools/mcp_server.zig:1420-1529,3205`; `la documentación interna:1019`).
3. JSON de capabilities con versión, tools, providers.

## Cliente Python de prueba

Ver `tests/mcp_external_client.py` para un cliente Python completo que
lanza el servidor, hace handshake, llama `capabilities`, `models_list`,
y ejecuta una orden E2E hasta `list_artifacts`.

```bash
python tests/mcp_external_client.py --exe zig-out\bin\devagents-mcp.exe --data-dir engine\data
```

## Tests

Los tests del servidor están en `tools/mcp_server.zig` (bloques `test`) y
se integran en `zig build test`:

```bash
zig build test -j1 --summary all
```

Los tests de la cabina nativa WebUI/Host están integrados en las suites de regresión nativas.

## Notas de implementación

- El servidor carga el core con `da_core_init(db_path)` y fallback a
  `:memory:` si no existe.
- Los `order_id` que cruza el protocolo MCP son enteros (punteros opacos
  codificados como `usize`); la conversión `orderIdToHandle` /
  `@intFromPtr` se hace internamente.
- Las cadenas devueltas por C-ABI (`da_*_json`) se liberan con
  `da_string_free` después de serializar la respuesta MCP.
- El servidor es **monohilo** y lee stdin línea por línea; no hay estado
  compartido entre clientes.
- `--data-dir` y `DEVAGENTS_DATA_DIR` permiten lanzar el servidor desde
  cualquier CWD sin depender de rutas relativas.
