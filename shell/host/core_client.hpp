#ifndef BEATS_CORE_CLIENT_HPP
#define BEATS_CORE_CLIENT_HPP

#include <atomic>
#include <functional>
#include <string>
#include <windows.h>

#include "engine_supervisor.hpp"

namespace beats {

struct CoreStatus {
  bool running = false;
  DWORD pid = 0;
  std::string version;
  std::string governanceMode;
  std::string activeModel;
  std::string activeProvider;
  std::string keyLabel;
  int keyCount = 0;
  int providerCount = 0;
  bool engineReady = false;
  DWORD lastError = 0;
  std::string initError;
  void *coreHandle = nullptr;
};

// Resultado uniforme de una llamada al motor: rc == 0 significa exito
// (da_error_code.ok). En caso de fallo, `error` lleva el texto de
// da_last_error para poder mostrarlo en la UI sin inventar mensajes.
struct CoreResult {
  int rc = -1;
  std::string json;
  std::string error;
  bool ok() const { return rc == 0; }
};

// Punteros a la API C del motor (c_api.zig) resueltos por GetProcAddress.
// Cualquiera puede ser nullptr si el DLL es de una version anterior; los
// metodos de CoreClient lo comprueban antes de llamar.
struct CoreApi {
  int (*models_selection_v1_json)(void *, char **) = nullptr;
  int (*model_preferences_set_v1_json)(void *, const char *, char **) = nullptr;
  // E5.29/E5.30: additive outgoing and remote broker contracts.
  int (*webhook_list_json)(void *, char **) = nullptr;
  int (*webhook_add)(void *, const char *, long long *) = nullptr;
  int (*webhook_delete)(void *, long long) = nullptr;
  int (*webhook_test)(void *, long long) = nullptr;
  int (*notifications_since_json)(void *, long long, char **) = nullptr;
  int (*remote_request_json)(void *, const char *, char **) = nullptr;
  // --- Ciclo de vida ---
  int (*core_init)(void **, const char *) = nullptr;
  int (*core_shutdown)(void *) = nullptr;
  const char *(*core_version)(void) = nullptr;
  const char *(*build_identity_v1)(void) = nullptr;
  int (*last_error)(char **) = nullptr;
  void (*string_free)(char *) = nullptr;

  // --- Ordenes: planificacion ---
  int (*order_from_issue_async)(void *, const char *, const char *,
                                const char *, const char *, void **) = nullptr;
  int (*issues_list_json)(void *, const char *, char **) = nullptr;
  int (*issue_read_json)(void *, const char *, char **) = nullptr;
  int (*issue_prompt_json)(void *, const char *, char **) = nullptr;
  int (*issue_comment_json)(void *, const char *, char **) = nullptr;
  int (*order_from_issue_images_async)(void *, const char *, const char *,
                                       const char *, const char *, const char *,
                                       void **) = nullptr;
  int (*order_submit_async)(void *, const char *, const char *, const char *,
                            void **) = nullptr;
  int (*order_submit_images_async)(void *, const char *, const char *,
                                   const char *, const char *,
                                   void **) = nullptr;
  int (*order_submit_options_async)(void *, const char *, const char *,
                                    const char *, const char *, const char *,
                                    void **) = nullptr;
  int (*order_replan_async)(void *, void *, const char *) = nullptr;
  int (*order_attachments_json)(void *, void *, char **) = nullptr;
  int (*vision_probe_json)(void *, const char *, const char *,
                           char **) = nullptr;
  int (*order_answer_async)(void *, void *, const char *) = nullptr;
  int (*order_plan_poll)(void *, int *, int *) = nullptr;
  int (*plan_get_json)(void *, void *, char **) = nullptr;
  int (*plan_set_json)(void *, void *, const char *) = nullptr;
  int (*plan_set_model)(void *, const char *, const char *) = nullptr;
  int (*plan_get_model)(void *, const char **, const char **) = nullptr;
  int (*exec_set_model)(void *, const char *, const char *) = nullptr;
  int (*exec_get_model)(void *, const char **, const char **) = nullptr;
  int (*audit_set_model)(void *, const char *, const char *) = nullptr;
  int (*audit_get_model)(void *, const char **, const char **) = nullptr;
  int (*swarm_set_models_json)(void *, const char *) = nullptr;
  int (*swarm_get_models_json)(void *, char **) = nullptr;
  // E5.08: agentes externos (registro/detección + límites gobernados).
  int (*order_preflight_json)(void *, char **) = nullptr;
  int (*external_agents_json)(void *, char **) = nullptr;
  int (*doctor_json)(void *, char **) = nullptr;
  // Tanda 5: actualizador (ver beats_core.h).
  int (*update_state_json)(void *, char **) = nullptr;
  int (*update_check_json)(void *, int, char **) = nullptr;
  int (*update_download_json)(void *, char **) = nullptr;
  int (*update_set_enabled)(void *, int) = nullptr;
  // T7 (e): reglas del proyecto por carpeta (catalog.db).
  int (*project_rules_get_json)(void *, char **) = nullptr;
  int (*project_rules_set)(void *, const char *) = nullptr;
  // T7 (f): varias cuentas por CLI (carpeta propia por cuenta).
  int (*cli_accounts_json)(void *, char **) = nullptr;
  int (*cli_account_add)(void *, const char *) = nullptr;
  int (*cli_account_remove)(void *, const char *) = nullptr;
  int (*cli_account_select)(void *, const char *) = nullptr;
  int (*update_set_apply_on_exit)(void *, int) = nullptr;
  int (*update_pending_apply_json)(void *, char **) = nullptr;
  int (*external_agents_refresh)(void *, char **) = nullptr;
  int (*external_paths_json)(void *, char **) = nullptr;
  int (*external_paths_set)(void *, const char *) = nullptr;
  int (*external_model_options_set)(void *, const char *) = nullptr;
  int (*external_limits_json)(void *, char **) = nullptr;
  int (*external_limits_set)(void *, const char *) = nullptr;
  int (*repo_search)(void *, const char *, char **) = nullptr;
  int (*embeddings_config_json)(void *, char **) = nullptr;
  int (*embeddings_config_set)(void *, const char *) = nullptr;
  // E5.15: índice vectorial persistente + probe vivo de embeddings.
  int (*repo_embed_index)(void *, const char *, char **) = nullptr;
  int (*repo_embed_status)(void *, const char *, char **) = nullptr;
  int (*embeddings_probe_json)(void *, const char *, char **) = nullptr;
  int (*set_direct_mode)(void *, int) = nullptr;
  int (*get_direct_mode)(void *, int *) = nullptr;
  int (*set_deterministic_mode)(void *, int) = nullptr;
  int (*get_deterministic_mode)(void *, int *) = nullptr;
  int (*role_set_model)(void *, const char *, const char *,
                        const char *) = nullptr;
  int (*role_models_json)(void *, char **) = nullptr;
  int (*swarm_set_enabled)(void *, int) = nullptr;
  int (*swarm_get_enabled)(void *, int *) = nullptr;
  int (*composer_review_json)(void *, char **) = nullptr;

  // --- Ordenes: ejecucion ---
  int (*order_approve)(void *, void *) = nullptr;
  int (*order_dispatch_async)(void *, void *) = nullptr;
  // CHECKPOINT-T2: reanuda una orden 'interrupted' desde su checkpoint por
  // tarea. Puede ser nullptr en DLLs antiguos — el puente lo comprueba.
  int (*order_resume_async)(void *, void *) = nullptr;
  // SEMANTIC-GATE-T3: observable declarado de la orden (aserciones JSON).
  int (*order_set_expected)(void *, void *, const char *) = nullptr;
  int (*order_expected_json)(void *, void *, char **) = nullptr;
  int (*order_dispatch_poll)(void *, void *, int *, int *) = nullptr;
  int (*order_cancel)(void *, void *) = nullptr;
  int (*plan_cancel)(void *, void *) = nullptr;
  int (*order_status)(void *, void *, int *) = nullptr;
  int (*order_events_json)(void *, void *, long long, char **) = nullptr;
  int (*set_agentic_max_iterations)(void *, unsigned int) = nullptr;
  int (*get_agentic_max_iterations)(void *, unsigned int *) = nullptr;

  // --- UI-ACTION: acciones cosméticas pedidas por agentes/ordenes ---
  int (*ui_action_request)(void *, const char *, long long,
                           long long *) = nullptr;
  int (*ui_actions_poll)(void *, long long, char **) = nullptr;
  int (*ui_action_ack)(void *, long long, int, const char *) = nullptr;
  // (b): primer arranque guardado en el motor.
  int (*onboarding_json)(void *, char **) = nullptr;
  int (*onboarding_done)(void *) = nullptr;

  // browser.v1: private transport, never exposed as generic bridge calls.
  int (*browser_host_attach_v1)(void *, const char *, char **) = nullptr;
  int (*browser_host_poll_v1)(void *, const char *, char **) = nullptr;
  int (*browser_host_complete_v1)(void *, const char *, const char *) = nullptr;
  int (*browser_control_v1)(void *, const char *, char **) = nullptr;
  int (*process_control_v1)(void *, const char *, char **) = nullptr;

  // --- Sesiones ---
  int (*sessions_json)(void *, char **) = nullptr;
  int (*sessions_json_filtered)(void *, int, char **) = nullptr;
  int (*session_archive)(void *, void *, int) = nullptr;
  int (*session_archive_before_preview)(void *, long long, int *) = nullptr;
  int (*session_archive_before)(void *, long long, int, int *) = nullptr;
  int (*session_messages_json)(void *, void *, char **) = nullptr;
  int (*session_messages_v2_json)(void *, void *, char **) = nullptr;
  int (*session_rename)(void *, void *, const char *) = nullptr;
  int (*session_delete)(void *, void *) = nullptr;
  int (*list_artifacts_json)(void *, long long, char **) = nullptr;

  // --- Proveedores, claves y modelos ---
  int (*provider_add)(void *, const char *, const char *,
                      const char *) = nullptr;
  int (*providers_list_json)(void *, char **) = nullptr;
  int (*key_add)(void *, const char *, const char *, const char *) = nullptr;
  int (*key_remove)(void *, const char *, const char *) = nullptr;
  int (*keys_json)(void *, char **) = nullptr;
  // E1.13 multi-cuenta: edita prioridad/cuota/estado de una clave.
  int (*key_set_meta)(void *, const char *, const char *, int, int,
                      const char *) = nullptr;
  int (*models_list_json)(void *, char **) = nullptr;
  int (*models_discover)(void *, int *) = nullptr;
  int (*model_register)(void *, const char *, const char *, int, int) = nullptr;
  int (*model_prioritize)(void *, const char *, const char *) = nullptr;
  int (*catalog_info_json)(void *, char **) = nullptr;
  int (*router_candidates_json)(void *, const char *, char **) = nullptr;

  // --- Salud y consumo ---
  int (*health_summary_json)(void *, char **) = nullptr;
  int (*health_detail_json)(void *, char **) = nullptr;
  int (*health_probe_all_json)(void *, int, char **) = nullptr;
  int (*usage_summary_json)(void *, int, char **) = nullptr;
  // E1.16/F4: medidor del plan (ventana 7 dias + claves limitadas).
  int (*usage_week_json)(void *, char **) = nullptr;
  // E1.18/F4: presupuesto de pago visible y editable.
  int (*budget_state_json)(void *, char **) = nullptr;
  int (*budget_set_authorized)(void *, int) = nullptr;
  int (*inventory_json)(void *, char **) = nullptr;
  int (*inventory_refresh)(void *) = nullptr;

  // --- Auditoria y gobernanza ---
  int (*audit_ledger_json)(void *, char **) = nullptr;
  int (*audit_checklist_json)(void *, char **) = nullptr;
  int (*ledger_escalations_json)(void *, char **) = nullptr;
  int (*approval_pending_json)(void *, char **) = nullptr;
  int (*approval_resolve)(void *, long long, int) = nullptr;
  int (*set_permission_config)(void *, const char *) = nullptr;
  int (*get_permission_config)(void *, char **) = nullptr;
  // Hooks de ciclo de vida: comandos que el usuario engancha antes o despues
  // de cada ejecucion y de cada escritura de archivo (core/src/hooks.zig).
  int (*set_hooks_config)(void *, const char *) = nullptr;
  int (*set_governance_mode)(void *, const char *) = nullptr;
  int (*get_governance_mode)(void *, char **) = nullptr;
  int (*set_reasoning_effort)(void *, const char *) = nullptr;
  int (*approval_resolve_scoped)(void *, long long, int, int) = nullptr;
  int (*specialists_json)(void *, char **) = nullptr;
  // Aprendizaje del router: puntuaciones por modelo y resumen de evolución.
  int (*model_scores_json)(void *, char **) = nullptr;
  int (*evolution_summary_json)(void *, char **) = nullptr;

  // --- Workspace y MCP ---
  int (*set_workspace_root)(void *, const char *) = nullptr;
  int (*mounts_list_json)(void *, char **) = nullptr;
  int (*mount_add)(void *, const char *) = nullptr;
  int (*mount_remove)(void *, const char *) = nullptr;
  int (*mcp_connect)(void *, const char *, const char *, int) = nullptr;
  int (*mcp_disconnect)(void *) = nullptr;
  int (*mcp_is_connected)(void *, int *) = nullptr;
  int (*mcp_tools_json)(void *, char **) = nullptr;
  int (*mcp_call_tool)(void *, const char *, const char *, char **) = nullptr;
  int (*mcp_auth_token)(void *, char **) = nullptr;
  int (*memory_context_json)(void *, const char *, char **) = nullptr;
  // Skills descubiertas en las carpetas enlazadas (mounts).
  int (*skills_discover_json)(void *, char **) = nullptr;
  // Favorito elegido por el usuario (antes solo lo ponia el router).
  int (*model_set_favorite)(void *, const char *, const char *, int) = nullptr;
  // Los montajes ya estaban resueltos mas arriba (mounts_list_json, mount_add,
  // mount_remove); lo que faltaba era exponerlos en el puente, no bindearlos.
  int (*web_search)(void *, const char *, int, char **) = nullptr;
  // Captura de la pantalla primaria a BMP. Estaba exportada en el .def y sin
  // resolver aqui, asi que era inalcanzable desde la cabina.
  int (*capture_screenshot)(void *, char **) = nullptr;
  // Spaces: un git worktree por orden, con su rama. El motor lo hacia desde F5
  // y no habia una sola funcion da_space* con la que alcanzarlo.
  int (*spaces_list_json)(void *, const char *, char **) = nullptr;
  int (*space_create)(void *, const char *, const char *, const char *,
                      char **) = nullptr;
  int (*space_archive)(void *, long long) = nullptr;
  int (*spaces_prune)(void *, const char *, unsigned int *) = nullptr;
  // E5.05: estado de .devagents/worktree.json del proyecto (existe, valido,
  // copias, setup, timeout, sugerencias por lockfiles). Inspeccion sin
  // ejecutar nada — la tarjeta de configuracion del SpacesPanel.
  int (*worktree_config_json)(void *, const char *, char **) = nullptr;
  // Ship Flow B3: plan->revisión->PR->merge sobre gh real (sin fabricar
  // estados: el JSON de salida viene de `gh pr create/view` parseado).
  int (*order_ship_json)(void *, void *, char **) = nullptr;
  int (*git_store_credential)(void *, const char *, char **) = nullptr;
  int (*pr_merge)(void *, long long, char **) = nullptr;
  int (*prs_json)(void *, long long, char **) = nullptr;
  int (*repo_clone)(void *, const char *, const char *) = nullptr;
  // La carpeta REAL donde la orden escribe (su worktree de space o la raíz).
  int (*order_worktree_json)(void *, void *, char **) = nullptr;
  // Plugins: plugin_loader.zig son 801 lineas con verificacion de ABI y anclaje
  // de confianza por SHA-256, y no habia una sola funcion da_plugin_* con la
  // que llegar hasta ahi.
  int (*plugins_list_json)(void *, char **) = nullptr;
  int (*plugin_trust)(void *, const char *) = nullptr;
  int (*plugin_untrust)(void *, const char *) = nullptr;
  int (*plugins_dir)(void *, char **) = nullptr;
  // Una llamada al modelo sin planificador ni orden (decision D4).
  int (*complete_text)(void *, const char *, const char *, char **) = nullptr;
  // E5.18 (D-C5): Best-of-N — opción de la orden, tarjeta comparativa y
  // elección del ganador (aplica el worktree de la candidata sobre la padre).
  int (*order_set_best_of_n)(void *, void *, int, const char *) = nullptr;
  int (*best_of_n_candidates_json)(void *, void *, char **) = nullptr;
  int (*best_of_n_choose)(void *, void *, long long) = nullptr;
};

class CoreClient {
public:
  enum class InitMode { user, isolated_empty };
  explicit CoreClient(InitMode mode = InitMode::user);
  bool SetWorkspaceRoot(const std::wstring &root, std::string &error);
  ~CoreClient();

  bool StartCoreProcess();
  void StopCoreProcess();
  bool RestartCoreProcess();
  void CheckProcessHealth();
  void SetRemoteStopHook(std::function<void()> hook) {
    m_remoteStopHook = std::move(hook);
  }
  void SetBrowserStopHook(std::function<void()> hook) {
    m_browserStopHook = std::move(hook);
  }
  const std::wstring &DataDirectory() const { return m_dataDirectory; }

  CoreStatus GetStatus() const;

  bool EngineReady() const {
    return m_hCoreDll != nullptr && m_coreEngineHandle != nullptr;
  }
  const CoreApi &Api() const { return m_api; }
  void *Handle() const { return m_coreEngineHandle; }

  // Ruta del runtime.db en uso (catalog.db y ledger.db son hermanos suyos).
  const std::string &RuntimeDbPath() const { return m_runtimeDbPath; }

  // Modo de gobernanza elegido por el usuario (free | paid | hybrid).
  // Persiste junto al runtime.db para sobrevivir reinicios.
  const std::string &GovernanceMode() const { return m_governanceMode; }
  bool SetGovernanceMode(const std::string &mode);

  // --- Helpers de invocacion ---------------------------------------------
  // Llama a una funcion `int fn(handle, char** out)` y devuelve el JSON,
  // liberando la cadena del lado del motor. Nunca lanza: los fallos vienen
  // en CoreResult.
  CoreResult CallJson(int (*fn)(void *, char **)) const;
  CoreResult CallJson(int (*fn)(void *, const char *, char **),
                      const std::string &arg_json) const;
  // Envuelve un rc ya obtenido, adjuntando da_last_error si fallo.
  CoreResult Wrap(int rc) const;
  // Toma posesion de una cadena del motor y la libera.
  std::string TakeString(char *s) const;
  // Texto de da_last_error (cadena vacia si no hay o no esta disponible).
  std::string LastEngineError() const;

private:
  void ResolveApi();
  void LoadGovernanceMode();

  HANDLE m_hProcess = nullptr;
  DWORD m_dwPid = 0;
  std::atomic<bool> m_isSupervised{false};
  mutable DWORD m_lastError = 0;
  std::wstring m_coreExePath;
  HMODULE m_hCoreDll = nullptr;
  void *m_coreEngineHandle = nullptr;
  CoreApi m_api;
  std::function<void()> m_remoteStopHook;
  std::function<void()> m_browserStopHook;
  std::wstring m_dataDirectory;
  std::string m_runtimeDbPath;
  std::wstring m_governanceFilePath;
  std::string m_governanceMode = "hybrid";
  std::string m_initError;
  // D4 tramo 2: da_status de la cabina va por el HIJO devagents-engine.exe
  // con reconexión, no por la DLL in-proc.
  EngineSupervisor m_engineSupervisor;
  bool m_engineSupervisorStarted = false;
};

} // namespace beats

#endif // BEATS_CORE_CLIENT_HPP
