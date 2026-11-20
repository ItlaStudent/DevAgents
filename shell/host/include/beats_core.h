#ifndef DEVAGENTS_CORE_H
#define DEVAGENTS_CORE_H

/*
 * DevAgents Core C API
 * =====================
 * Frontera C pura entre el núcleo Zig y el IDE C++/Qt (ADR-001).
 * Tipos opacos, extern "C", sin dependencias Zig/C++ en la interfaz.
 * Convención: el llamador libera strings con da_string_free.
 * Códigos de retorno: 0 = DA_OK, >0 = error.
 * Formato de intercambio: JSON (std.json.Stringify del lado Zig,
 * NUNCA interpolación manual).
 */

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

/*, additive v1: read metadata/preferences; set both switches and
 * return order preflight (including independent-auditor warnings).
 * Request: {provider,model,show_in_selectors:boolean,allow_automatic:boolean}.
 */
int da_models_selection_v1_json(void *handle, char **out_json);
int da_model_preferences_set_v1_json(void *handle, const char *request_json,
                                     char **out_json);

/* ── Versión ─────────────────────────────────────────────────────────── */

#define DA_CORE_VERSION_MAJOR 0
#define DA_CORE_VERSION_MINOR 1
#define DA_CORE_VERSION_PATCH 0

/* ── Códigos de retorno ──────────────────────────────────────────────── */

typedef enum {
  DA_OK = 0,
  DA_ERR_NOT_FOUND = 1,
  DA_ERR_INVALID_STATE = 2,
  DA_ERR_INVALID_ARG = 3,
  DA_ERR_INTERNAL = 4,
  DA_ERR_OOM = 5,
  DA_ERR_NOT_IMPLEMENTED = 6,
} DaResult;

/* ── Estado de orden ─────────────────────────────────────────────────── */

typedef enum {
  DA_ORDER_PENDING = 0,
  DA_ORDER_CLARIFYING = 1,
  DA_ORDER_PLANNED = 2,
  DA_ORDER_APPROVED = 3,
  DA_ORDER_RUNNING = 4,
  DA_ORDER_DONE = 5,
  DA_ORDER_FAILED = 6,
  DA_ORDER_REJECTED = 7,
  DA_ORDER_AWAITING_APPROVAL = 8,
  /* Append-only ABI: la cancelación del usuario (plan o despacho). */
  DA_ORDER_CANCELLED = 9,
  /* Hilo vivo al morir el proceso; lo escribe la reconciliación de arranque. */
  DA_ORDER_INTERRUPTED = 10,
  /* AUDIT-UNAVAILABLE-P0: ejecución terminada sin veredicto de auditoría
     usable. Ni done ni failed — entrega bloqueada hasta reintento manual. */
  DA_ORDER_AUDIT_UNAVAILABLE = 11,
} DaOrderStatus;

/* ── Handles opacos ──────────────────────────────────────────────────── */

typedef struct DaCoreHandle DaCoreHandle;
typedef struct DaOrderHandle DaOrderHandle;

/* browser.v1, additive transport. Strings belong to core; da_string_free.
 * attach config: schema, canonical order_id/workspace_root, host_instance.
 * The returned opaque host_capability stays exclusively in the native host.
 * poll is nonblocking (up to 8 claims); complete consumes a claim once.
 * DaResult reports ABI rejection; out JSON reports typed operation errors.
 * control is the trusted human host path, never a worker/model operation. */
DaResult da_browser_host_attach_v1(DaCoreHandle *handle,
                                   const char *config_json, char **out_json);
DaResult da_browser_host_poll_v1(DaCoreHandle *handle,
                                 const char *host_capability, char **out_json);
DaResult da_browser_host_complete_v1(DaCoreHandle *handle,
                                     const char *host_capability,
                                     const char *completion_json);
DaResult da_browser_control_v1(DaCoreHandle *handle,
                               const char *trusted_control_json,
                               char **out_json);
DaResult da_process_control_v1(DaCoreHandle *handle, const char *control_json,
                               const char **out_json);

/* ── Ciclo de vida ───────────────────────────────────────────────────── */

/** Inicializa el núcleo. `db_path` puede ser ":memory:" para tests. */
DaResult da_core_init(DaCoreHandle **out_handle, const char *db_path);

/** Apaga el núcleo y libera todos los recursos. */
DaResult da_core_shutdown(DaCoreHandle *handle);

/* ── Órdenes ─────────────────────────────────────────────────────────── */

/** Envía una orden en lenguaje natural. `out_order` recibe el handle.
 *  `conversation_id` (opcional, puede ser NULL): hilo de conversación — si se
 *  provee, el planner recupera el historial real de TODAS las órdenes previas
 *  de ese mismo hilo (loop agéntico, FASE 1). NULL = sin hilo explícito. */
DaResult da_order_submit(DaCoreHandle *handle, const char *order_text,
                         const char *project_id, const char *conversation_id,
                         DaOrderHandle **out_order);

/** Responde preguntas de clarificación. `answers_json` es array JSON
 *  [{"question_id":"q1","answer":"respuesta"}]. */
DaResult da_order_answer(DaCoreHandle *handle, DaOrderHandle *order,
                         const char *answers_json);

/*, contrato aditivo v1: {wait_for_plan_approval:bool,
 * issue_request?:string}. Captura el modo antes de arrancar el planificador. */
DaResult da_order_submit_options_async(
    DaCoreHandle *handle, const char *order_text, const char *project_id,
    const char *conversation_id, const char *attachments_json,
    const char *options_json, DaOrderHandle **out_order);
/* Replanifica la misma orden no aprobada; sin despachar workers. */
DaResult da_order_replan_async(DaCoreHandle *handle, DaOrderHandle *order,
                               const char *changes);
/* Solo planifica: understanding, questions[], tasks[]; liberar con
 * da_string_free. */
DaResult da_order_plan_json(DaCoreHandle *handle, const char *order_text,
                            char **out_json);

/** Envía una orden en lenguaje natural de forma asíncrona (F7-ASYNC-PLAN).
 *  No bloquea UI; consulta progreso con da_order_plan_poll y da_order_status.
 *  `conversation_id`: ver da_order_submit. */
DaResult da_order_submit_async(DaCoreHandle *handle, const char *order_text,
                               const char *project_id,
                               const char *conversation_id,
                               DaOrderHandle **out_order);

/** Responde preguntas de clarificación de forma asíncrona (F7-ASYNC-PLAN).
 *  No bloquea UI; consulta progreso con da_order_plan_poll. */
DaResult da_order_answer_async(DaCoreHandle *handle, DaOrderHandle *order,
                               const char *answers_json);

/** Consulta si una planificación/respuesta async ha terminado. out_done=1 si
 * terminó, out_ok=1 si tuvo éxito (solo válido cuando out_done=1). */
DaResult da_order_plan_poll(DaCoreHandle *handle, int *out_done, int *out_ok);

/** Aprueba el plan y despacha tareas a workers. */
DaResult da_order_approve(DaCoreHandle *handle, DaOrderHandle *order);

/**
 * Confirma un plan (posiblemente editado) y lo despacha.
 * `plan_json` usa el mismo esquema que devuelve da_plan_get_json (objeto con
 * understanding y tasks[]). Las clarificaciones pendientes deben resolverse
 * primero con da_order_answer.
 */
DaResult da_order_confirm_json(DaCoreHandle *handle, DaOrderHandle *order,
                               const char *plan_json);

/** Guarda el plan JSON editado sin despachar. La GUI lo usa antes de
 *  da_order_dispatch_async para evitar el bloqueo síncrono. */
DaResult da_order_plan_set_json(DaCoreHandle *handle, DaOrderHandle *order,
                                const char *plan_json);

/** Inicia despacho async de la orden en un hilo en segundo plano (F7-ASYNC).
 *  Retorna inmediatamente; consulta progreso con da_order_dispatch_poll
 *  y da_order_status. No bloquea el hilo de UI. */
DaResult da_order_dispatch_async(DaCoreHandle *handle, DaOrderHandle *order);

/** Cancela un despacho activo de la orden. */
DaResult da_order_cancel(DaCoreHandle *handle, DaOrderHandle *order);

/** PLAN-CANCEL: cancela la planificación en curso (submit/answer async).
 *  `order` puede ser NULL (cancela la planificación actual) o debe ser la
 *  orden que se está planificando. La orden queda en estado `cancelled`. */
DaResult da_plan_cancel(DaCoreHandle *handle, DaOrderHandle *order);

/** Consulta si un despacho async ha terminado. out_done=1 si terminó,
 *  out_ok=1 si tuvo éxito (solo válido cuando out_done=1). */
DaResult da_order_dispatch_poll(DaCoreHandle *handle, DaOrderHandle *order,
                                int *out_done, int *out_ok);

/** Consulta el estado actual de la orden. */
DaResult da_order_status(DaCoreHandle *handle, DaOrderHandle *order,
                         DaOrderStatus *out_status);

/** UX-13: lista todas las órdenes/sesiones activas como array JSON
 *  [{id,title,status,status_text,created_at}]. El llamador libera con
 *  da_string_free. */
DaResult da_sessions_json(DaCoreHandle *handle, char **out_json);

/** SESSIONS-PERSIST-06: devuelve los mensajes de una sesión como JSON array
 *  [{id,role,content,created_at}]. El llamador libera con da_string_free. */
DaResult da_session_messages_json(DaCoreHandle *handle, DaOrderHandle *order,
                                  char **out_json);

/** Version 2: full conversation of the selected order; legacy orders stay
 * isolated.
 * [{id,order_id,role,content,created_at}], ordered by timestamp
 * then message id.
 * Unknown orders and storage errors return nonzero. Free
 * with da_string_free.
 * The unversioned da_session_messages_json stays scoped
 * to one order. */
DaResult da_session_messages_v2_json(DaCoreHandle *handle, DaOrderHandle *order,
                                     char **out_json);
/** P4: devuelve el timeline completo de una sesión (mensajes + eventos +
 * metadatos de orden) para replay. El llamador libera con da_string_free. */
DaResult da_session_timeline_json(DaCoreHandle *handle, DaOrderHandle *order,
                                  int64_t offset, int64_t limit,
                                  char **out_json);

/** SESSIONS-PERSIST-06: renombra una sesión (persiste title en runtime.db). */
DaResult da_session_rename(DaCoreHandle *handle, DaOrderHandle *order,
                           const char *title);

/* ── Plan ────────────────────────────────────────────────────────────── */

/** Obtiene el plan de la orden en formato JSON. El llamador libera con
 *  da_string_free. */
DaResult da_plan_get_json(DaCoreHandle *handle, DaOrderHandle *order,
                          char **out_json);

/** Fija el modelo forzado para planificación (F7-MODEL-SELECT).
 *  provider/model NULL o vacío → modo automático (router). */
DaResult da_plan_set_model(DaCoreHandle *handle, const char *provider,
                           const char *model);

/** Devuelve el modelo forzado para planificación.
 *  El caller debe liberar ambos strings con da_string_free. */
DaResult da_plan_get_model(DaCoreHandle *handle, char **out_provider,
                           char **out_model);

/** ROLES-MODELO: fija el modelo del EJECUTOR (tareas constructoras y
 *  correcciones). NULL/vacío = sigue al pin de la orden (da_plan_set_model). */
DaResult da_exec_set_model(DaCoreHandle *handle, const char *provider,
                           const char *model);

/** ROLES-MODELO: pin específico del ejecutor (NULL = sigue al de la orden). */
DaResult da_exec_get_model(DaCoreHandle *handle, char **out_provider,
                           char **out_model);

/** ROLES-MODELO: fija el modelo del AUDITOR (solo tareas .auditar). NULL/vacío
 *  = sigue al pin de la orden; nunca hereda el pin del ejecutor. */
DaResult da_audit_set_model(DaCoreHandle *handle, const char *provider,
                            const char *model);

/** ROLES-MODELO: pin específico del auditor (NULL = sigue al de la orden). */
DaResult da_audit_get_model(DaCoreHandle *handle, char **out_provider,
                            char **out_model);

/** ENJAMBRE: fija el conjunto cerrado de modelos para las tareas productoras.
 *  `json` = `[{provider,model}]`; NULL, "" o "[]" = Automático (router decide).
 *  Máximo 8 miembros; la forma se valida y se guarda normalizada. */
DaResult da_swarm_set_models_json(DaCoreHandle *handle, const char *json);

/** ENJAMBRE: conjunto fijado como JSON `[{provider,model}]` ("[]" =
 * Automático). El caller libera con da_string_free. */
DaResult da_swarm_get_models_json(DaCoreHandle *handle, char **out_json);

/** E5.08 — agentes externos (GOBIERNO ENCIMA): detecta los CLIs instalados y
 *  devuelve `[{id, provider, cli, exe, version, acp, permission_note,
 *  turn_cap_note, manufacturer, subscription, available}]`. Las entradas no
 *  instaladas figuran con available=false. El caller libera con
 *  da_string_free. */
DaResult da_order_preflight_json(DaCoreHandle *handle, char **out_json);
DaResult da_external_agents_json(DaCoreHandle *handle, char **out_json);
/* Tanda 4 (F0.5): comprobación antes de la primera orden (JSON v1). */
DaResult da_doctor_json(DaCoreHandle *handle, char **out_json);
/* Tanda 5 (F0.4): actualizador «avisar y aplicar al cerrar». state, check y
 * download devuelven el estado JSON (enabled, current, checked_ms, status,
 * detail, latest, staged, apply_on_exit, download_error). check con force != 0
 * ignora las 24 h; desactivado no sale a la red. pending_apply devuelve
 * {apply, path, reason}: ruta solo si hay algo preparado, aceptado, más nuevo,
 * con la misma huella y sin órdenes en curso. El caller libera con
 * da_string_free. */
DaResult da_update_state_json(DaCoreHandle *handle, char **out_json);
DaResult da_update_check_json(DaCoreHandle *handle, int force, char **out_json);
DaResult da_update_download_json(DaCoreHandle *handle, char **out_json);
DaResult da_update_set_enabled(DaCoreHandle *handle, int enabled);
/* apply: 0 = no, 1 = yes (only with a verifiable publisher signature),
 * 2 = yes accepting "sin firma verificable" (T12 M3, explicit consent). */
DaResult da_update_set_apply_on_exit(DaCoreHandle *handle, int apply);
DaResult da_update_pending_apply_json(DaCoreHandle *handle, char **out_json);
/* T7 (e): reglas del proyecto abierto. get devuelve {projectRoot,
 * custom, rules, defaultRules, projectDocs, precedence, maxBytes}; set recibe
 * {"rules":"..."} o {"reset":true} y se rechaza en un núcleo con superficie
 * MCP. */
DaResult da_project_rules_get_json(DaCoreHandle *handle, char **out_json);
DaResult da_project_rules_set(DaCoreHandle *handle, const char *json);
/* T7 (f): cuentas por CLI (Codex: CODEX_HOME; Claude Code:
 * CLAUDE_CONFIG_DIR) en <datos>\cli-accounts. Rechazadas en un núcleo MCP. */
DaResult da_cli_accounts_json(DaCoreHandle *handle, char **out_json);
DaResult da_cli_account_add(DaCoreHandle *handle, const char *json);
DaResult da_cli_account_remove(DaCoreHandle *handle, const char *id);
DaResult da_cli_account_select(DaCoreHandle *handle, const char *json);
DaResult da_external_agents_refresh(DaCoreHandle *handle, char **out_json);
DaResult da_external_paths_json(DaCoreHandle *handle, char **out_json);
DaResult da_external_paths_set(DaCoreHandle *handle, const char *json);
DaResult da_external_model_options_set(DaCoreHandle *handle, const char *json);

/** E5.08: límites vigentes de los agentes externos como JSON
 *  {task_timeout_ms, task_max_turns, order_timeout_ms, order_max_turns}.
 *  El caller libera con da_string_free. */
DaResult da_external_limits_json(DaCoreHandle *handle, char **out_json);

/** E5.08: fija los límites desde un JSON parcial (claves ausentes conservan
 *  el valor vigente; 0 = sin tope). Persiste en settings del catálogo. */
DaResult da_external_limits_set(DaCoreHandle *handle, const char *json);

/** E5.14 — repo_search: ranking BM25 (lexico) sobre los archivos rastreados
 *  por git del repositorio. Entrada JSON: {"query":string, "root?":string,
 *  "max_results?":int}. Salida JSON: {query_mode:"bm25", truncated,
 *  elapsed_ms, files_seen, files_scanned, chunks_total, matches:[{path,
 *  line, snippet, score}]}. `root` omitida = raiz efectiva del workspace.
 *  NO es busqueda semantica (E5.15). El caller libera con da_string_free. */
DaResult da_repo_search(DaCoreHandle *handle, const char *query_json,
                        char **out_json);

/** E5.15 — config de la capa semantica {enabled, provider, model}.
 *  enabled=true autoriza a enviar chunks del repo al endpoint de embeddings
 *  del proveedor. El caller libera con da_string_free. */
DaResult da_embeddings_config_json(DaCoreHandle *handle, char **out_json);
/** E5.15: fija la config desde JSON parcial (claves ausentes conservan el
 *  valor vigente). Persiste en settings.embeddings_config. */
DaResult da_embeddings_config_set(DaCoreHandle *handle, const char *json);

/** E5.15 — construye/actualiza el índice vectorial persistente del repo
 *  (repo_embeddings; incremental por hash de trozo, embebido por lotes, con
 *  la puerta de presupuesto y reintento 429). Entrada {"root?":string}.
 *  Salida {indexed, reason?, model, files_scanned, chunks_total, embedded,
 *  reused, removed, batches, dim, elapsed_ms, retries_429, error?,
 *  truncated?}. Emite evento `repo_embed_indexed`. El caller libera con
 *  da_string_free. */
DaResult da_repo_embed_index(DaCoreHandle *handle, const char *query_json,
                             char **out_json);

/** E5.15 — estado del índice vectorial. Entrada {"root?","model?"}; sin
 *  modelo informa el índice más reciente. Salida {state:"empty"|"ready",
 *  chunks_indexed, files_indexed, model, updated_at}. El caller libera. */
DaResult da_repo_embed_status(DaCoreHandle *handle, const char *query_json,
                              char **out_json);

/** E5.15 — sondeo EN VIVO de cap_embeddings para (provider, model); sin args
 *  usa settings.embeddings_config. Persiste cap_embeddings_*='live_probe'
 *  solo en veredicto del endpoint (yes|no). Salida {ok, status, provider,
 *  model, dim?, elapsed_ms, retries_429, reason?}. El caller libera. */
DaResult da_embeddings_probe_json(DaCoreHandle *handle, const char *query_json,
                                  char **out_json);

/** Modo determinista: con un modelo fijado por da_plan_set_model, prohíbe los
 *  respaldos en toda la orden (planificación, cada tarea y la corrección). Ese
 *  modelo hace el trabajo entero o la orden falla nombrándolo.
 *  Sin modelo fijado no tiene efecto. enabled: 0 = apagado, distinto de 0 = on.
 */
DaResult da_set_deterministic_mode(DaCoreHandle *handle, int enabled);

/** Estado actual del modo determinista (0/1), para que la UI lo refleje en vez
 *  de suponerlo apagado tras un reinicio. */
DaResult da_get_deterministic_mode(DaCoreHandle *handle, int *out_enabled);

/** modo Directo («un solo modelo, como una CLI»). La orden no se
 *  planifica: el modelo elegido (o el primero apto en Automático) responde y
 *  trabaja con las herramientas gobernadas sobre la carpeta del proyecto. */
DaResult da_set_direct_mode(DaCoreHandle *handle, int enabled);
DaResult da_get_direct_mode(DaCoreHandle *handle, int *out_enabled);
/* additive specialist role pins (second_audit/programmer/sidekick).
 */
DaResult da_role_set_model(DaCoreHandle *handle, const char *role,
                           const char *provider, const char *model);
DaResult da_role_models_json(DaCoreHandle *handle, char **out_json);
DaResult da_swarm_set_enabled(DaCoreHandle *handle, int enabled);
DaResult da_swarm_get_enabled(DaCoreHandle *handle, int *out_enabled);
DaResult da_composer_review_json(DaCoreHandle *handle, char **out_json);

/** Tope de iteraciones del loop agéntico observe→re-planifica. 1 = un solo
 *  paso (estable). >=2 activa replanificación autónoma. Acotado a [1,12]. */
DaResult da_set_agentic_max_iterations(DaCoreHandle *handle,
                                       unsigned int max_iterations);

/** Estado actual del tope agéntico (1..12), para que la UI lo muestre en vez
 *  de suponer 1 tras un reinicio. */
DaResult da_get_agentic_max_iterations(DaCoreHandle *handle,
                                       unsigned int *out_iterations);

/* ── Modelos ─────────────────────────────────────────────────────────── */

/** Lista los modelos registrados en el catálogo como string formateado.
 *  El llamador libera con da_string_free. */
DaResult da_models_list_json(DaCoreHandle *handle, char **out_json);

/** Salud de modelos (HEALTH-02): resumen por proveedor en JSON
 *  [{provider,models,ok_models,ok_rate,total_ok,total_fail}] desde runtime.db.
 *  El llamador libera con da_string_free. */
DaResult da_health_summary_json(DaCoreHandle *handle, char **out_json);

/** Salud de modelos detallada (HEALTH-04): por (proveedor, modelo) con status
 *  diferenciado (ok/empty/auth_failed/quota/rate_limited/not_found/err).
 *  El llamador libera con da_string_free. */
DaResult da_health_detail_json(DaCoreHandle *handle, char **out_json);

/** Proveedores, claves (sin texto cifrado) y modelos del catálogo en JSON.
 *  El llamador libera con da_string_free. */
DaResult da_providers_list_json(DaCoreHandle *handle, char **out_json);

/** Info del catálogo cargado: ruta absoluta y conteos. NUNCA la clave en claro.
 *  Devuelve objeto JSON
 * {catalog_path_abs,model_count,provider_count,key_count}. El llamador libera
 * con da_string_free. */
DaResult da_catalog_info_json(DaCoreHandle *handle, char **out_json);

/** PIXEL-DEVTEAM-05: registro unificado de especialistas (5 nativos + dev-team
 * de Pixel Enterprise) y divisiones. Objeto JSON
 *  {"specialists":[{name,department,source,task_types[],model_hint,description}],
 *   "divisions":[{id,name,emoji,room_id,agent_ids[]}]}.
 * source="native"|"pixel". NUNCA incluye secretos. El llamador libera con
 * da_string_free. */
DaResult da_specialists_json(DaCoreHandle *handle, char **out_json);

/** Candidatos del router para una tarea: score, why=, free/paid.
 *  `task_type`: texto de la taxonomía.
 *  El llamador libera con da_string_free. */
DaResult da_router_candidates_json(DaCoreHandle *handle, const char *task_type,
                                   char **out_json);

/** Filas ESCALATION del ledger append-only (auditoría de escaladas a pago).
 *  El llamador libera con da_string_free. */
DaResult da_ledger_escalations_json(DaCoreHandle *handle, char **out_json);

/** Lista TODAS las acciones del audit_ledger (no solo ESCALATION).
 *  Devuelve array JSON
 * [{ts,subject_kind,subject_id,action,verdict,model_id,provider,evidence_ref,notes}].
 * Ordenado por id DESC, límite 200. El llamador libera con da_string_free. */
DaResult da_audit_ledger_json(DaCoreHandle *handle, char **out_json);

/** Estado de checklist derivado del audit_ledger por subject.
 *  Devuelve [{subject_kind,subject_id,status,builder,auditors[]}] donde status
 *  es pending|built|audited|verified|reopened (o chain_broken si la cadena de
 *  hashes no verifica). Solo-lectura. El llamador libera con da_string_free. */
DaResult da_audit_checklist_json(DaCoreHandle *handle, char **out_json);

/** CHECKLIST.md parseado a JSON (solo-lectura; no modifica).
 *  El llamador libera con da_string_free. */
DaResult da_checklist_json(DaCoreHandle *handle, char **out_json);

/** Web search: busca en la web usando Tavily (con clave), Brave Search (con
 * clave) o DuckDuckGo (sin clave, default). Devuelve JSON:
 *  {"provider":"...","results":[{"title":"...","url":"...","snippet":"..."}]}
 *  Best-effort: en caso de error devuelve results:[] y error:"...". NUNCA
 * incluye la clave. El llamador libera con da_string_free. */
DaResult da_web_search(DaCoreHandle *handle, const char *query, int max_results,
                       char **out_json);

/* ── Workers / Consolas ──────────────────────────────────────────────── */

/** Streaming de salida de workers por polling. `since_ms` es timestamp
 *  Unix en milisegundos; devuelve salida nueva desde esa marca.
 *  `out_json` es array JSON de eventos [{worker_id, stream, text, ts}].
 *  El llamador libera con da_string_free. */
DaResult da_worker_output_poll(DaCoreHandle *handle, int64_t since_ms,
                               char **out_json);

/** UX-08: timeline de progreso de una orden. `since_event_id` filtra eventos
 *  con id > since_event_id (polling incremental). Devuelve array JSON de
 *  eventos [{id,ts,source,kind,title,severity,payload}].
 *  El llamador libera con da_string_free. */
DaResult da_order_events_json(DaCoreHandle *handle, DaOrderHandle *order,
                              int64_t since_event_id, char **out_json);

/** Shell/terminal interactiva gobernada (UX-11). `command_json` es un objeto
 *  {"exe":"...","args":["..."],"cwd":"...","timeout_ms":N}. El comando se
 *  ejecuta SIEMPRE por la política del executor (allowlist + sandbox de cwd +
 *  Job Object + timeout). Un escáner de seguridad bloquea argumentos con .db u
 *  operaciones destructivas y lo devuelve visible en `out_json`:
 *  {"blocked":bool,"block_reason":"...","exit_code":int,"stdout":"...","stderr":"..."}.
 *  El llamador libera con da_string_free. */
DaResult da_shell_run(DaCoreHandle *handle, const char *command_json,
                      char **out_json);

/** Lanza un proceso independiente (detached) para apps GUI/autocontenidas.
 *  `command_json`: {"exe":"python","args":["clock.py"],"cwd":"..."}.
 *  Valida allowlist + sandbox igual que da_shell_run, pero NO captura salida
 *  ni espera a que termine. Devuelve {"ok":bool,"pid":uint,"error":"..."}.
 *  El llamador libera con da_string_free. */
DaResult da_run_detached(DaCoreHandle *handle, const char *command_json,
                         char **out_json);

/* ── Memoria ─────────────────────────────────────────────────────────── */

/** Obtiene el contexto de memoria para un proyecto en formato JSON.
 *  El llamador libera con da_string_free. */
DaResult da_memory_context_json(DaCoreHandle *handle, const char *project,
                                char **out_json);

/* ── Aprobaciones ────────────────────────────────────────────────────── */

/** Obtiene aprobaciones pendientes como array JSON.
 *  El llamador libera con da_string_free. */
DaResult da_approval_pending_json(DaCoreHandle *handle, char **out_json);

/** Resuelve una aprobación pendiente. `approved`: 1 = aprobar, 0 = rechazar. */
DaResult da_approval_resolve(DaCoreHandle *handle, int64_t approval_id,
                             int approved);

/* ── Error ───────────────────────────────────────────────────────────── */

/** Devuelve el último mensaje de error. El llamador libera con
 *  da_string_free. */
DaResult da_last_error(char **out_error);

/* ── Utilidad ────────────────────────────────────────────────────────── */

/** Libera una cadena devuelta por cualquier función da_*. */
void da_string_free(char *str);

/* ── Información ─────────────────────────────────────────────────────── */

/** Versión del núcleo como string (p.ej. "0.1.0"). */
const char *da_core_version(void);

/* ── Administración de proveedores, claves y modelos ─────────────────── */

/** Registra un proveedor en el catálogo. */
DaResult da_provider_add(DaCoreHandle *handle, const char *name,
                         const char *api_style, const char *base_url);

/** Añade una clave API cifrada con DPAPI para un proveedor. */
DaResult da_key_add(DaCoreHandle *handle, const char *provider,
                    const char *label, const char *key);

/** Registra un modelo en el catálogo asociado a un proveedor.
 *  `context`: tamaño de contexto (>0); `is_free`: 1 = free tier, 0 = pago. */
DaResult da_model_register(DaCoreHandle *handle, const char *provider,
                           const char *model, int context, int is_free);

/** Prioriza un modelo en el catálogo estableciendo su puntuación máxima. */
DaResult da_model_prioritize(DaCoreHandle *handle, const char *provider,
                             const char *model);

/** Descubrimiento VIVO: para cada proveedor con clave, pide su /models real y
 * puebla el catálogo (reemplazando el contenido previo). `out_count` recibe el
 * nº de modelos descubiertos. Best-effort: proveedores que fallan se saltan. */
DaResult da_models_discover(DaCoreHandle *handle, int *out_count);

/* ── Skills / Mounts (SKILLS-RUNTIME-01) ───────────────────────────── */

/** Agrega una ruta al registro de mounts activos. `path`: directorio raíz que
 *  contiene carpetas de skills (<name>/SKILL.md). */
DaResult da_mount_add(DaCoreHandle *handle, const char *path);

/** Elimina una ruta del registro de mounts activos. `path`: ruta exacta
 *  previamente registrada. */
DaResult da_mount_remove(DaCoreHandle *handle, const char *path);

/** Lista todos los mounts registrados como JSON array
 * [{id,path,added_at,active}]. El llamador libera con da_string_free. */
DaResult da_mounts_list_json(DaCoreHandle *handle, char **out_json);

/** Descubre skills desde los mounts activos y devuelve el inventario como JSON.
 *  El llamador libera con da_string_free. */
DaResult da_skills_discover_json(DaCoreHandle *handle, char **out_json);

/** P12-T1: Devuelve el inventario UNIFICADO como JSON (skills + MCPs + plugins
 * + webhooks). Incluye cost y source por recurso. Fusiona tools de MCPs
 * conectados. El llamador libera con da_string_free. */
DaResult da_inventory_json(DaCoreHandle *handle, char **out_json);

/** P12-T1: Invalida el cache del inventario para forzar re-escaneo. */
DaResult da_inventory_refresh(DaCoreHandle *handle);

/* ── Open Design MCP integration (OD-MCP-01) ───────────────────────── */

/** Conecta al servidor MCP de open-design-bridge.
 *  `argv_json`: array JSON de strings (ej.
 * ["python","-m","od_bridge.mcp_server"]). `cwd`: directorio de trabajo (puede
 * ser NULL). Env vars OD_WSL_DISTRO/OD_HOME deben estar seteadas en el entorno
 * del proceso. */
DaResult da_mcp_connect(DaCoreHandle *handle, const char *argv_json,
                        const char *cwd, int timeout_ms);

/** Desconecta del servidor MCP de Open Design. */
DaResult da_mcp_disconnect(DaCoreHandle *handle);

/** Estado de conexión: out_connected = 1 si conectado, 0 si no. */
DaResult da_mcp_is_connected(DaCoreHandle *handle, int *out_connected);

/** Lista las tools del servidor MCP como JSON array.
 *  El llamador libera con da_string_free. */
DaResult da_mcp_tools_json(DaCoreHandle *handle, char **out_json);

/** Llama una tool del servidor MCP.
 *  Devuelve objeto JSON {"content":"...","is_error":bool}.
 *  El llamador libera con da_string_free. */
DaResult da_mcp_call_tool(DaCoreHandle *handle, const char *name,
                          const char *args_json, char **out_result);

/** MCP-AUTH: devuelve el token de autenticación del servidor MCP propio
 *  (devagents-mcp) para que la cabina lo muestre al usuario al configurar
 *  clientes MCP/IDEs externas. Cadena vacía si no hay token resuelto.
 *  El llamador libera con da_string_free. */
DaResult da_mcp_auth_token(DaCoreHandle *handle, char **out_token);

/* ── Permission system (P2: Devin-style autonomy modes + prefix lists) ── */

/** Sets permission mode and allow/deny prefix lists.
 *  config_json:
 * {"mode":"normal|accept_edits|bypass|autonomous","allow":["git"],"deny":["rm"]}
 */
DaResult da_set_permission_config(DaCoreHandle *handle,
                                  const char *config_json);

/** Resolves an approval with scope. scope: 0=once, 1=session, 2=always.
 *  For session/always, adds the approval's command_prefix to the corresponding
 * set. */
DaResult da_approval_resolve_scoped(DaCoreHandle *handle, int64_t approval_id,
                                    int approved, int scope);

/** QA-B: read-only status of an approval requested over MCP and, once the
 *  cabin executed it, its bounded result. out_json: {approval_id, status:
 *  pending|approved|denied|unknown, kind, executed, result?}. */
DaResult da_approval_result_json(DaCoreHandle *handle, int64_t approval_id,
                                 char **out_json);

/** T12 M5: the MCP surface records each project file it wrote with fs_write
 *  (event mcp_file_written_v1); command approval cards requested over MCP
 *  then warn about recent writes. Rejected for a non-MCP core. */
DaResult da_mcp_file_written(DaCoreHandle *handle, const char *path);
/** Project-scoped MCP write notification (v2). */
DaResult da_mcp_file_written_v2(DaCoreHandle *handle, const char *project_root,
                                const char *path);

/** T12B: sets the stable, non-secret MCP approval origin before dispatch.
 *  The server supplies a digest of token and client identity, never a key. */
DaResult da_set_mcp_session(DaCoreHandle *handle, const char *tag);

/* ── Token Usage Summary (P08) ── */

/** Returns JSON summary of token usage. order_id=0 for global totals.
 *  Caller frees with da_string_free. */
DaResult da_usage_summary_json(DaCoreHandle *handle, int order_id,
                               char **out_json);

/* E5.29/E5.30: additive contracts; returned JSON uses da_string_free. */
DaResult da_webhook_list_json(DaCoreHandle *handle, char **out_json);
DaResult da_webhook_add(DaCoreHandle *handle, const char *config_json,
                        long long *out_id);
DaResult da_webhook_delete(DaCoreHandle *handle, long long id);
DaResult da_webhook_test(DaCoreHandle *handle, long long id);
DaResult da_notifications_since_json(DaCoreHandle *handle, long long after_id,
                                     char **out_json);
DaResult da_remote_request_json(DaCoreHandle *handle, const char *request_json,
                                char **out_json);

#ifdef __cplusplus
}
#endif

#endif /* DEVAGENTS_CORE_H */
