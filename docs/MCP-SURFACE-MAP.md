> SNAPSHOT P08-T1 — los estados de esta matriz corresponden a esa generación y no son un censo actual de cobertura. El estado de trabajo se mantiene en la documentación interna; el registro de auditorías conserva los resultados fechados.

# DevAgents — Mapa de Superficie UI ↔ MCP

Documento generado por P08-T1. Mapea cada acción de UI de la cabina nativa DevAgents
con su tool MCP equivalente. Estado: **CUBIERTA** / **PARCIAL** / **SIN TOOL**.

## Matriz cabina / MCP / CLI vigente (T7, 13-nov-2026)

Decisión del propietario del 13-nov («paridad sin gobierno», la documentación interna): el MCP
expone lo que hace la cabina con un proyecto (archivos, terminal, git, spaces,
aprobar y replanificar el plan, archivar) y negocia el protocolo actual;
cambiar permisos, aprobaciones de comandos, reglas de gobierno, límites, cupo
de gasto, hooks, plugins y servidores MCP queda **solo en la cabina**. Un agente
conectado no puede aflojar sus propias barreras. El ejecutable de la CLI es
`devagents.exe` (mismo binario que `devagents-core.exe`); el instalador ofrece
añadirlo al PATH del usuario.

**Protocolo** (`tools/mcp_server.zig`, `negotiateProtocolVersion`): 2024-11-05,
2025-03-26, 2025-06-18 y 2025-11-25. Si el cliente pide una de ellas se
devuelve la misma; si no, 2025-11-25. `ping`, `resources/list`,
`resources/templates/list` y `prompts/list` responden vacíos y bien formados;
ids de cadena se devuelven tal cual; a una notificación no se responde; lotes
JSON-RPC solo con 2025-03-26; con 2025-11-25 un argumento que no cumple el
esquema vuelve como resultado `isError` (SEP-1303). Las tools marcadas
`x-devagents-privileged` exigen el token del panel MCP.

| Acción | Cabina (puente) | MCP (tool) | CLI (`devagents …`) |
|---|---|---|---|
| Lanzar una orden | `core.order.submit` | `da_submit_order`, `da_submit_order_async`, `order_submit` | `order "<texto>"`, `design` |
| Ver plan / estado / eventos | `core.order.plan`, `core.order.status`, `core.order.events` | `get_plan`, `plan_poll`, `order_status`, `order_events`, `order_progress` | `debug <id>` |
| Aprobar el plan | `core.order.dispatch` | `plan_approve` (privilegiada) | `order "<texto>" --yes` |
| Replanificar | `core.order.replan` | `plan_replan` (privilegiada) | — |
| Cancelar | `core.order.cancel`, `core.plan.cancel` | `dispatch_cancel`, `plan_cancel` | — |
| Archivar / restaurar sesión | `core.session.archive` | `session_archive` (privilegiada) | — |
| Listar spaces | `core.spaces.list` | `spaces_list` | — |
| Crear / archivar / podar spaces | `core.space.create`, `core.space.archive`, `core.spaces.prune` | `space_create`; `space_archive` y `spaces_prune` con aprobación humana en dos fases | — |
| Listar / leer / buscar archivos | `fs.list`, `doc.open`, `search.query` | `fs_list`, `fs_read`, `fs_search` (tools `list_dir`, `read_file`, `grep_files` del agente, mismo confinamiento; T12 M4: privilegiadas, porque dan el contenido del proyecto —incluidos `.env` y claves del proyecto—, igual que `git_diff`). QA-B 2b: raíz por defecto = la carpeta del proyecto elegida, como el modo Directo (la raíz efectiva si no hay ninguna) | — |
| Escribir archivos | `doc.save` | `fs_write` (tool `write_file` del agente; privilegiada; misma raíz que `fs_read`; nunca dentro de `.git`). Escribe sin tarjeta, como los agentes de la cabina con el plan aprobado y como Claude Code y Codex (editar dentro del proyecto no pide permiso; ejecutar sí). **Advertencia (T12 M5): un comando aprobado después puede ejecutar archivos que este cliente escribió (`package.json`, scripts); la tarjeta de aprobación lo indica**: cada escritura deja el evento `mcp_file_written_v1` y la tarjeta de un comando pedido por MCP en los 10 minutos siguientes dice cuántos archivos escribió un cliente MCP y cuáles | — |
| Terminal | `pty.*` (terminal integrada) | `shell_run` (lista de programas, denylist, `command_policy.decide`: lo que la política exime corre y devuelve su salida; el resto pide tarjeta en la cabina y devuelve `approval_id`). Raíz por defecto `devagents-workspace` (QA-A H2); `root:"project"` ancla en la carpeta del proyecto con las mismas reglas | — |
| Resultado de una aprobación | tarjeta de la cabina | `approval_result {approval_id}` (QA-B 2a, privilegiada, solo lectura): `pending`/`approved`/`denied`/`unknown` y, si la cabina ya lo ejecutó, `exit_code`, `stdout` y `stderr` acotados a 16 KiB, o la ruta de la captura. T12 L1: solo de las aprobaciones que pidió la misma sesión MCP (el mismo proceso `devagents-mcp`); otra sesión, aunque tenga token, recibe un error | — |
| git status / diff / log | `core.git.status` | `git_status`, `git_diff`, `git_log` (git domesticado de la cabina —sin hooks, fsmonitor, bloqueos opcionales ni firmas—, por la puerta de `shell_run`). QA-B 2a: son la consulta exacta que `command_policy` exime, así que corren sin tarjeta y devuelven su salida; raíz = carpeta del proyecto elegida | — |
| git add / commit | `core.git.commit` | `git_add`, `git_commit` (sin hooks, nunca `--amend`; misma puerta; escriben: tarjeta en la cabina, resultado con `approval_result`) | — |
| Capturar la pantalla | paleta «Capturar la pantalla en un archivo» (`core.screenshot`, acción humana) | `capture_screenshot` (QA-B H4): registra la tarjeta y no captura nada; la cabina la toma al aprobarla y el cliente recoge la ruta con `approval_result`. T12 A1: `screenshot` (nombre antiguo) es un alias con la misma aprobación; el proceso MCP ya no tiene captura propia | — |
| git push / reescribir historial | `core.order.ship`, `core.pr.merge` (consentimiento nativo) | **no** (`ship_order`/`pr_merge` siguen siendo el flujo de entrega de una orden) | — |
| Elegir modelos | `core.exec.setModel`, `core.audit.setModel`, `core.plan.setModel`, `core.swarm.setModels` | `exec_set_model`, `audit_set_model`, `plan_set_model`, `swarm_set_models` | `chat --model`, `order --provider --model` |
| Claves API | `core.keys.*` | `add_key`, `remove_key`, `list_keys` | `key-admin.exe` |
| Salud / modelos | `core.health*`, `core.models.*` | `health`, `health_summary`, `models_list`, `discover_models` (T12 A1: privilegiada, llama a `/models` de cada proveedor con sus claves) | `health`, `models list/discover/roster` |
| Modo y reglas de permisos | `core.permissions.set` | **SOLO CABINA** | — |
| Resolver aprobaciones de comandos | `core.approvals.resolve`, `core.approvals.resolveScoped` | **SOLO CABINA** (`approvals_list` sí, para ver) | — |
| Rutas y límites de agentes externos | `core.external.paths.set`, `core.external.limits.set` | **SOLO CABINA** (lecturas `external_paths_get`, `external_limits_get` abiertas) | — |
| Iteraciones del bucle agéntico | `core.agentic.setIterations` | **SOLO CABINA** | — |
| Cupo de gasto de pago / modo de gobernanza | `core.budget.set`, `core.governance.set` | **SOLO CABINA** (`paid_budget_get` abierta) | `governance` (proceso local del usuario) |
| Hooks | `core.hooks.set` | **SOLO CABINA** | — |
| Plugins | `core.plugin.trust`, `core.plugin.untrust` | **SOLO CABINA** | — |
| Conectar servidores MCP | `core.mcp.connect` | **SOLO CABINA** | — |

T12 A1 (auditorías del modelo y el segundo auditor): toda tool anunciada tiene clase, y la
prueba «T12 A1: toda tool anunciada tiene clase…» de `tools/mcp_server.zig`
falla si aparece una sin clasificar. Abiertas sin credencial solo quedan las de
lectura del estado de DevAgents, con su motivo escrito una a una en
`T12_OPEN_TOOLS`; todo lo demás exige el token (`PRIVILEGED_TOOLS`), y las que
ven la pantalla, ejecutan o escriben con git (`screenshot`,
`capture_screenshot`, `shell_run`, `run_detached`, `git_add`, `git_commit`,
`spaces_prune`/`space_archive`) además dejan la tarjeta para el humano. Pasaron
a privilegiadas en T12: `fs_read`, `fs_list`, `fs_search` (M4), `repo_search`
(lee el proyecto y, en modo semántico, lo manda al proveedor de embeddings),
`discover_models` (red con las claves) y `agents_external_refresh` (lanza las
CLIs instaladas).

Las tools de la fila «SOLO CABINA» no se anuncian en `tools/list` y una llamada
con su nombre responde `isError` sin tocar el motor (`CABIN_ONLY_TOOLS`,
prueba «T7: ninguna herramienta de gobierno se expone por MCP y la cabina sigue
pudiendo»). La tabla de abajo es la instantánea P08 y conserva su historia.

## Leyenda

- **CUBIERTA**: La tool MCP existe y cubre completamente la acción de UI.
- **PARCIAL**: La tool MCP existe pero no cubre todos los aspectos de la UI.
- **SIN TOOL**: No hay tool MCP equivalente (la acción es puramente UI/IDE).

## Comandos de UI → Tool MCP

### Chat / Órdenes

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.newOrder` | `da_submit_order` / `da_submit_order_async` | **CUBIERTA** |
| `devagents.newConversation` | (reinicia contexto de chat en la UI) | **SIN TOOL** — es estado local del IDE |
| `devagents.approveFromChat` | `confirm_plan` | **CUBIERTA** |
| `devagents.rehydrateChat` | `session_messages` / `session_timeline` | **CUBIERTA** |
| `devagents.triggerCascade` | (abre panel de chat en la UI) | **SIN TOOL** — es navegación local del IDE |

### Mission Control / Plan

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openMissionControl` | `get_plan` | **CUBIERTA** |
| `devagents.injectMockTimeline` | (test-only, no producción) | **SIN TOOL** — test interno |

### Aprobaciones

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.refreshApprovals` | `approvals_list` | **CUBIERTA** |
| `devagents.approveApproval` | — | **SOLO CABINA** (T7: `approvals_resolve*` salieron del MCP) |
| `devagents.rejectApproval` | — | **SOLO CABINA** (T7) |

### Tareas / Workers

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.refreshTasks` | `order_status` / `order_events` / `worker_output` | **CUBIERTA** |
| `devagents.openShell` | `shell_run` | **CUBIERTA** |

### Spaces

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `core.space.create` (crear space manual) | `space_create` | **CUBIERTA** (añadida en) |
| `core.space.archive` (archivar space) | `space_archive` | **CUBIERTA** (añadida en; r3: aprobación humana real en dos fases — fase 1 registra solicitud pendiente en runtime.db y responde approval_id; fase 2 con `approval_id` ejecuta solo si el humano la concedió desde otro núcleo sin superficie MCP, como la cabina; r4: la solicitud aparece en la bandeja de la cabina (`da_approval_pending_json`) y la aprobación es de un solo uso) |
| `core.spaces.prune` (podar spaces archivados) | `spaces_prune` | **CUBIERTA** (añadida en; r3: aprobación humana real en dos fases, igual que `space_archive`; r4: un solo uso; r5: poda SOLO los ids del snapshot que el humano vio, comprobando por id que sigan archivados — lo archivado después nunca se toca; r6: el motor ejecuta `da_spaces_prune_ids` y retira worktree y rama por space igual que la poda normal, en vez de un DELETE directo) |

### Sesiones

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.refreshSessions` | `sessions` | **CUBIERTA** |
| `devagents.openSession` | `session_messages` / `session_timeline` | **CUBIERTA** |
| `devagents.openSessions` | `sessions` | **CUBIERTA** |
| Renombrar sesión (UI) | `session_rename` | **CUBIERTA** (añadida en P08) |

### Archivos / Artefactos

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openFiles` | `list_artifacts` | **CUBIERTA** |
| `devagents.openGeneratedFile` | `list_artifacts` + lectura de archivo | **PARCIAL** — `list_artifacts` lista; abrir requiere el IDE |
| `devagents.reviewGeneratedFile` | `list_artifacts` + diff del IDE | **PARCIAL** — el diff es capacidad del IDE |
| `devagents.reviewChanges` | `list_artifacts` | **CUBIERTA** |

### Proveedores / Salud

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.refreshProviders` | `health` / `health_summary` | **CUBIERTA** |
| `devagents.openHealth` | `health` / `health_summary` / `health_probe_all` | **CUBIERTA** |
| `devagents.openRouter` | `router_candidates` | **CUBIERTA** |

### Catálogo / Modelos

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openCatalog` | `catalog_info` / `models_list` / `router_candidates` | **CUBIERTA** |
| Discover models (botón Settings) | `discover_models` | **CUBIERTA** |
| Leer capacidades, gratuidad y permisos por modelo (20-oct-2026) | `models_selection_v1` | **CUBIERTA** |
| Mostrar en selectores / Permitir al router y al enjambre | `models_preferences_set_v1` (`json` con proveedor, modelo y ambos booleanos; autenticación requerida) | **CUBIERTA**; devuelve preflight y aviso de auditor independiente |
| Listar claves (panel Settings) | `list_keys` | **CUBIERTA** (ya implementada) |
| Añadir clave (panel Settings) | `add_key` | **CUBIERTA** (ya implementada) |
| Eliminar clave (panel Settings) | `remove_key` | **CUBIERTA** (ya implementada) |
| Forzar modelo (dropdown) | `plan_set_model` / `plan_get_model` | **CUBIERTA** (ya funcional) |

### Gobernanza

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openLedger` | `ledger_escalations` / `audit_ledger` | **CUBIERTA** |
| `devagents.openMemory` | `memory_context` | **CUBIERTA** |

### Especialistas

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openSpecialists` | `specialists` | **CUBIERTA** |

### Skills / Mounts / Addons

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openAddons` | `skills_discover` / `mount_add` / `mounts_list` / `mount_remove` | **CUBIERTA** |
| `devagents.openKnowledge` | `skills_discover` | **CUBIERTA** |

### Canvas / Preview

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openCanvas` | `preview` | **CUBIERTA** |
| `devagents.openPreview` | `preview` | **CUBIERTA** |

### Verificación

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openVerification` | `order_events` (timeline con eventos de verificación) | **PARCIAL** — la UI muestra un panel dedicado; MCP da eventos crudos |

### Preferencias / Permisos

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openPreferences` | — | **SOLO CABINA** (T7: `set_permission_config` salió del MCP) |
| `devagents.setModeAgent` | — | **SOLO CABINA** (T7) |
| `devagents.setModeChat` | — | **SOLO CABINA** (T7) |
| `devagents.setModeWrite` | — | **SOLO CABINA** (T7) |

### Engine / Settings

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.pingEngine` | `capabilities` (incluye versión y estado) | **CUBIERTA** |
| `devagents.restartEngine` | (el cliente MCP reinicia el proceso) | **SIN TOOL** — es ciclo de vida del proceso |
| `devagents.openSettings` | `catalog_info` / `providers` (via capabilities) | **CUBIERTA** |

### Layout / Welcome / Diff

| Comando UI | Tool MCP | Estado |
|---|---|---|
| `devagents.openWelcome` | (página de bienvenida del IDE) | **SIN TOOL** — es UI local |
| `devagents.applyLayout` | (layout del IDE) | **SIN TOOL** — es UI local |
| `devagents.restoreLayout` | (layout del IDE) | **SIN TOOL** — es UI local |
| `devagents.focus` | (foco del IDE) | **SIN TOOL** — es UI local |
| `devagents.toggleViewMode` | (modo agente/editor del IDE) | **SIN TOOL** — es UI local |
| `devagents.openAgentCenter` | (navegación del IDE) | **SIN TOOL** — es UI local |
| `devagents.switchToEditor` | (navegación del IDE) | **SIN TOOL** — es UI local |
| `devagents.editInline` | (edición inline del IDE) | **SIN TOOL** — es capacidad del editor |
| `devagents.acceptDiff` | (aplicar diff del IDE) | **SIN TOOL** — es capacidad del editor |
| `devagents.rejectDiff` | (rechazar diff del IDE) | **SIN TOOL** — es capacidad del editor |
| `devagents.focusNextHunk` | (navegación de diff del IDE) | **SIN TOOL** — es capacidad del editor |
| `devagents.focusPreviousHunk` | (navegación de diff del IDE) | **SIN TOOL** — es capacidad del editor |

### Web Search

| Acción UI | Tool MCP | Estado |
|---|---|---|
| Búsqueda web (chat) | `web_search` | **CUBIERTA** |

### Uso / Tokens

| Acción UI | Tool MCP | Estado |
|---|---|---|
| Resumen de uso de tokens | `usage_summary` | **CUBIERTA** |

### MCP externo

| Acción UI | Tool MCP | Estado |
|---|---|---|
| Conectar MCP externo | `mcp_connect` | **SOLO CABINA** — lanza un proceso; no se ofrece por MCP |
| Desconectar MCP externo | `mcp_disconnect` | **CUBIERTA** |
| Estado conexión MCP | `mcp_is_connected` | **CUBIERTA** |
| Listar tools MCP externo | `mcp_tools` | **CUBIERTA** |
| Llamar tool MCP externo | `mcp_call_tool` | **CUBIERTA** |

### Captura de pantalla

| Acción UI | Tool MCP | Estado |
|---|---|---|
| Screenshot | `screenshot` (alias de `capture_screenshot`: aprobación humana en la cabina) | **CUBIERTA** |

## Paneles (views) → Tool MCP

| Panel UI | Tool MCP de lectura | Estado |
|---|---|---|
| `devagents.chat` (webview) | `da_submit_order` + `get_plan` + `confirm_plan` + `order_events` | **CUBIERTA** |
| `devagents.router` (webview) | `router_candidates` | **CUBIERTA** |
| `devagents.health` (webview) | `health` / `health_summary` / `health_probe_all` | **CUBIERTA** |
| `devagents.ledger` (webview) | `ledger_escalations` / `audit_ledger` | **CUBIERTA** |
| `devagents.memory` (webview) | `memory_context` | **CUBIERTA** |
| `devagents.sessions` (tree) | `sessions` | **CUBIERTA** |
| `devagents.tasks` (tree) | `order_status` / `order_events` | **CUBIERTA** |
| `devagents.subagents` (tree) | `order_events` (eventos de worker) | **PARCIAL** — no hay tool dedicada a sub-agentes |
| `devagents.generatedFiles` (tree) | `list_artifacts` | **CUBIERTA** |
| `devagents.providers` (tree) | `health` / `providers` (via capabilities) | **CUBIERTA** |
| `devagents.approvals` (tree) | `approvals_list` | **CUBIERTA** |

| Comando UI | Equivalente MCP / Nota | Estado |
|---|---|---|
| `devagents.newConversation` | `da_submit_order` (inicia nueva conversación con un id de orden nuevo) | **CUBIERTA** |
| `devagents.restartEngine` | Reinicio de proceso mediante reconexión del transporte stdio | **CUBIERTA** |

## Resumen

- **Total acciones de motor en UI**: 100% mapeadas a Tools MCP
- **Acciones CUBIERTAS**: 55+
- **Acciones puramente locales del IDE**: 10 (layout de ventanas, foco de cursor, navegación de pestañas locales). Estas acciones no alteran el estado del motor ni requieren tool backend.

Todas las acciones del motor expuestas en la interfaz gráfica poseen su tool MCP descubrible y estructurada correspondiente.

## Tools MCP sin equivalente directo en UI

| Tool MCP | Origen | Nota |
|---|---|---|
| `capabilities` | P08-T4 | Punto de entrada para cualquier IDE nuevo |
| `run_detached` | Core | Lanzar procesos GUI sin capturar salida |
| `screenshot` | P-VIS | T12 A1: alias de `capture_screenshot` (tarjeta en la cabina; nada se captura sin aprobar) |

## Tools añadidas en P08

| Tool | Tarea | Descripción |
|---|---|---|
| `capabilities` | T4 | Metadatos del motor: versión, tools, rutas, proveedores |
| `session_rename` | T1 | Renombrar sesión (persiste en runtime.db) |
| `health_summary` | T1 | Resumen de salud por proveedor (más ligero que `health`) |
