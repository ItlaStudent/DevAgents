# Guía de Integración MCP — DevAgents

Documento de referencia para integradores y clientes MCP externos (Claude Code, Cursor, Zed, Codex).

---

## 1. Línea de Lanzamiento y Handshake

### 1.1 Ejecución del servidor MCP

`devagents-mcp.exe` funciona como servidor MCP nativo sobre `stdio` (JSON-RPC 2.0 delimitado por saltos de línea `\n`).

```powershell
# Invocación directa
devagents-mcp.exe --data-dir "%LOCALAPPDATA%\DevAgents"

# Invocación con CWD arbitrario (neutralidad CWD)
Set-Location C:\
& "C:\Ruta\A\devagents-mcp.exe" --data-dir "C:\Proyectos\MiProyecto"
```

Resolución de directorio de datos (`--data-dir`):
1. Parámetro CLI `--data-dir <ruta>`
2. Variable de entorno `BEATS_DATA_DIR`
3. Ubicación por defecto del usuario (`%LOCALAPPDATA%\DevAgents`)

### 1.2 Handshake Inicial (`initialize`)

**Petición Cliente → Servidor**:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": { "tools": {} },
    "clientInfo": { "name": "claude-code", "version": "1.0.0" }
  }
}
```

**Respuesta Servidor → Cliente**:
```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "protocolVersion": "2024-11-05",
    "capabilities": { "tools": {} },
    "serverInfo": { "name": "devagents-mcp", "version": "1.0.0" }
  }
}
```

**Notificación Cliente → Servidor (obligatoria tras initialize)**:
```json
{
  "jsonrpc": "2.0",
  "method": "notifications/initialized",
  "params": {}
}
```

---

## 2. Configuración para Clientes

### 2.1 Claude Code (`.mcpServers.json` / `claude.json`)

```json
{
  "mcpServers": {
    "devagents": {
      "command": "C:\\DevAgents\\devagents-mcp.exe",
 "args": ["--data-dir", "C:\\devagents\\mi-proyecto"]
    }
  }
}
```

### 2.2 Configuración Genérica MCP (Cursor / Zed)

```json
{
  "mcpServers": {
    "devagents-engine": {
      "command": "devagents-mcp.exe",
      "args": ["--data-dir", "%LOCALAPPDATA%\\DevAgents"],
      "env": {
 "BEATS_DATA_DIR": "C:\\DevAgents\\Data"
      }
    }
  }
}
```

---

## 3. Los Tres Flujos Principales

### Flujo 1 — Orden E2E de Programación
`capabilities → da_submit_order → plan_poll → confirm_plan → dispatch_poll → list_artifacts`

1. **`capabilities`**: Inspeccionar versión del motor, estado de claves y tools disponibles.
2. **`da_submit_order`**: Enviar la orden en lenguaje natural con el `workspace_root`.
3. **`plan_poll`**: Sondear el estado del plan en generación.
4. **`confirm_plan`**: Aprobar la ejecución del plan generado.
5. **`dispatch_poll`**: Esperar la conclusión del worker.
6. **`list_artifacts`**: Obtener los archivos modificados o artefactos generados.

### Flujo 2 — Salud, Proveedores y Catálogo
`capabilities → models_list → health_probe_all → router_candidates`

1. **`capabilities`**: Obtener la lista de proveedores (`has_active_key`, `key_count`).
2. **`models_list`**: Listar modelos activos en el catálogo de SQLite.
3. **`health_probe_all`**: Sondas activas de disponibilidad sobre los modelos free
 generativos. Acepta `max_models` (entero; desde el 01-09, un tipo incorrecto
   responde `-32602` en el acto en vez de colgar la petición). **Limitación conocida:** con modelos de razonamiento el ping puede clasificar `empty` a modelos que
   sí responden — el conteo de «vivos» que produce queda sub-medido; el diagnóstico
   fiable por modelo es `health probe --provider P --model M` del CLI.
4. **`router_candidates`**: Consultar qué modelos recomienda el router agéntico para una tarea dada.

### Flujo 3 — Sesiones e Historial
`sessions → session_messages → order_events`

1. **`sessions`**: Consultar las sesiones de chat históricas registradas en `runtime.db`.
2. **`session_messages`**: Recuperar todos los mensajes de una conversación.
3. **`order_events`**: Obtener la línea de tiempo de eventos y ejecuciones de herramientas.

#### Eventos de preparación del worktree (E5.04/E5.05)

En `order_events` aparecen también los cuatro eventos del ciclo de
preparación del worktree (`.devagents/worktree.json`):

| `kind` | Cuándo | Campos relevantes del payload |
|--------|--------|-------------------------------|
| `worktree_prepare_started` | Al crear el space, antes de copiar/configurar | `project`, `space`, `worktree`, `is_non_git` |
| `worktree_prepared` | Preparación completada | `copied`, `skipped_existing`, `skipped_missing`, `setup` (`"ran"`/`"none"`) |
| `worktree_setup_failed` | Fallo de copia, config o setup — la orden cae con esta causa | `cause` (`invalid_config`, `pending_approval`, `executor_rejected`, `setup_failed`, `Copy*`, `SetupScriptInvalid`), `detail`, `script`, `exit_code`, `timed_out`, `output_tail` (≤4 KiB) |
| `worktree_setup_suggested` | Sin `worktree.json`: comandos inferidos de lockfiles, **sin ejecutarse** | `detected[]`, `commands[]` |

La aprobación pendiente de un script de setup aparece en `approvals_list` con
`command_prefix: "worktree_script"` y `args_json` con
`{"project_id","script_sha256","script"}`: al resolverla con
`approvals_resolve`, la concesión queda ligada al par (proyecto, sha256) — si
el script cambia, el motor vuelve a pedir aprobación.

---

## 4. Respuestas de Error Estructuradas

Todas las herramientas devuelven respuestas con contrato estable en formato JSON:

```json
{
  "ok": false,
  "code": "WRITER_LOCKED",
  "message": "Otro proceso (PID 1234) sostiene el lock de escritura. Reintente en modo lectura.",
  "holder_pid": 1234
}
```

Códigos de error estándar:
- `WRITER_LOCKED`: Base de datos locked por otro cliente/escritor.
- `ORDER_NOT_FOUND`: El ID de orden especificado no existe.
- `INVALID_ARG`: Parámetros de entrada no válidos según `inputSchema`.
- `TIMEOUT`: Expiración de tiempo límite de ejecución.

## E5.55 / E5.56 — Modelos de CLIs de agente

| Herramienta | Argumentos | Resultado |
|---|---|---|
| `agents_external_list` | `{}` | Catálogo cacheado: `provider`, `cli`, `exe`, `version`, `selection_reason`, `session`, `detected_at_ms`, `enumeration_status`, `authenticode`, `authenticode_code`, `acl_appcontainer_sids[]`, `models[]`. Los SID de paquete/capacidad AppContainer aceptados se registran como señal; escritura de usuarios/grupos normales se rechaza. |
| `agents_external_refresh` | `{}` | Redetección sin inferencia; reemplaza la caché de cinco minutos. |
| `external_paths_get` | `{}` | Ajuste `external_agent_paths`, objeto CLI → ruta forzada. |
| `external_paths_set` | — | **Solo cabina** desde T7 (Configuración › Agentes externos); por MCP queda `external_paths_get`. |
| `external_model_options_set` | `{"json":"{\"provider\":\"agent:codex\",\"model\":\"gpt-6-luna\",\"reasoning_effort\":\"high\"}"}` | Persiste esfuerzo declarado por el catálogo; vacío conserva el defecto de la CLI. Requiere autenticación MCP. |

Cada modelo tiene `slug`, `display_name`, `manufacturer`, `reasoning_efforts` y,
si se fijó, `reasoning_effort`. Los pines existentes (`exec_set_model`,
`audit_set_model`, `swarm_set_models`) usan `agent:codex` + `gpt-6-luna`,
sin convertir el slug en un proveedor nuevo. La planificación por CLI no está
incluida en este bloque. Los fabricantes de gateway se resuelven por modelo;
fabricante desconocido no acredita independencia del auditor.

Descubrimiento acotado a instalaciones confiables: PATH solo dentro de raíces
permitidas, `%APPDATA%/npm/<cli>.cmd`, `%LOCALAPPDATA%/Programs/<CLI>` y Codex en
`%LOCALAPPDATA%/OpenAI/Codex/bin/codex.exe` y sus subdirectorios inmediatos
(máximo 64, sin junctions). Gana la versión semver mayor; una ruta forzada gana
por ajuste explícito. No hay exploración general del disco. Cada comando tiene
plazo de ocho segundos y salida máxima de 4 MiB; un catálogo inválido, truncado
o vencido se presenta como no enumerable con un único modelo `default`.
Rutas forzadas y despacho repiten las comprobaciones de origen, handles,
reparse/UNC/ADS y ACL; Authenticode se registra como señal adicional. Sondas
con entorno mínimo y facturación por nombre, incluyendo `CODEX_API_KEY`.
Política y límites: las comprobaciones de confianza descritas en esta sección.

Codex usa `debug models` y `login status`; Claude `auth status` y `--help`
para esfuerzo; OpenCode `models` y `auth list`. Gemini no expone lista ni estado
sin inferencia en el help medido: `default`, sesión desconocida. La detección
no lee archivos de credenciales ni invoca modelos. Sesiones: `suscripcion`
(«tu suscripción»), `api_key` (facturación API, pin bloqueado), `sin_sesion`
(pin bloqueado), `desconocida` (aviso visible). Las variables de facturación
se comprueban por nombre, nunca se muestran sus valores. El motor refresca al
arrancar en segundo plano; la cabina ofrece «Volver a detectar» y ruta opcional
en el detalle, con paridad MCP.

**Verificación del constructor sin cuota**, con binarios de su prefijo y datos
temporales exclusivos:

```powershell
& tools/e5_b13_evidence.ps1 -Mode live
```

**Cabina: recorrido pendiente según la documentación interna,.** Reconstruir/sincronizar
el WebUI y la DLL de este bloque antes de abrir la la sala de diseño; el constructor no lanza el host.

```powershell
$env:DEVAGENTS_CDP_PORT='9333'
$e556Prefix='la documentación interna'+(Get-Date -Format yyyyMMdd-HHmmss)
node tools/cdp_e556_models.mjs $e556Prefix > "$e556Prefix.txt" 2>&1
```

El driver refresca por el botón, exige gpt-6-luna bajo Codex y suscripción,
comprueba el detalle binario/versión, fija el segundo auditor como auditor sin productor y
como ejecutor, y exige rechazo visible al auditor OpenAI con productor OpenAI.
Guarda PNG e `innerText` a escalas 100 % y 150 %, consola y reporte JSON;
restaura los pines al finalizar; también fija y restaura el segundo auditor en el enjambre.
No lanza órdenes. El coordinador debe revisar las capturas. La orden real con
el segundo auditor sigue pendiente según la documentación interna, comprobar eventos del agente,
`argv_censored` con el binario detectado y `-m gpt-6-luna`, artefactos/gates y
auditor de otro fabricante. El catálogo demuestra disponibilidad declarada
por la CLI; no demuestra que una orden viva termine correctamente.
