#include "core_client.hpp"
#include "../../core/src/private_data_security.h"
#include "themed_dialog.hpp"
#include "version_policy.hpp"
#include <filesystem>
#include <fstream>
#include <iostream>
#include <shlobj.h>
#include <vector>

namespace beats {

namespace {

std::string WideToUtf8Local(const std::wstring &wstr) {
  if (wstr.empty())
    return "";
  int size = WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), (int)wstr.size(),
                                 nullptr, 0, nullptr, nullptr);
  std::string str(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wstr.c_str(), (int)wstr.size(), &str[0], size,
                      nullptr, nullptr);
  return str;
}

// Directorio de datos del usuario: %LOCALAPPDATA%\DevAgents-Angel (Angel,
// 8-nov). Las claves API (DPAPI) y el catalogo viven aqui, NO en el arbol del
// repositorio, para que sobrevivan a rebuilds y no acaben en git.
//
// el host replica EXACTAMENTE el orden de la funcion unica del
// nucleo (core/src/paths.zig resolveDataDir), que no puede usarse aqui porque
// vive en la DLL y el directorio se necesita antes de cargarla:
// BEATS_DATA_DIR > DEVAGENTS_DATA_DIR (alias) > API de carpetas conocidas.
std::wstring UserDataDir() {
  // Explicit data root for portable installations and isolated product runs.
  // Invalid overrides fail closed instead of falling back to the owner's DB.
  const wchar_t *overrides[] = {L"BEATS_DATA_DIR", L"DEVAGENTS_DATA_DIR"};
  for (const wchar_t *name : overrides) {
    const DWORD length = GetEnvironmentVariableW(name, nullptr, 0);
    if (!length)
      continue;
    std::wstring path(length, L'\0');
    const DWORD copied = GetEnvironmentVariableW(name, path.data(), length);
    if (!copied || copied >= length)
      return {};
    path.resize(copied);
    if (path.size() < 3 || path[1] != L':' ||
        (path[2] != L'\\' && path[2] != L'/') ||
        !((path[0] >= L'A' && path[0] <= L'Z') ||
          (path[0] >= L'a' && path[0] <= L'z')))
      return {};
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        !(attributes & FILE_ATTRIBUTE_DIRECTORY))
      return {};
    if (private_data_directory(path.c_str()) != ERROR_SUCCESS)
      return {};
    return path;
  }
  wchar_t localAppData[MAX_PATH];
  // se elimina el antiguo fallback C:\tmp\DevAgents. Si la API de
  // carpetas conocidas no devuelve LOCAL_APPDATA no hay carpeta de datos, y el
  // host no debe abrir ninguna otra base (fallo cerrado, igual que la CLI y el
  // MCP): abrir una ruta relativa o de otro usuario es justo el fallo.
  if (!SUCCEEDED(SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0,
                                  localAppData)))
    return {};
  const std::wstring dir =
      std::wstring(localAppData) +
      L"\\DevAgents-Angel"; // Angel: datos propios, separados de DevAgents
                            // (propietario, 8-nov)
  if (private_data_directory(dir.c_str()) != ERROR_SUCCESS)
    return {};
  return dir;
}

template <typename T> void Resolve(HMODULE mod, const char *name, T &slot) {
  slot = reinterpret_cast<T>(GetProcAddress(mod, name));
}

} // namespace

void CoreClient::ResolveApi() {
  HMODULE m = m_hCoreDll;
  if (!m)
    return;

  Resolve(m, "da_webhook_list_json", m_api.webhook_list_json);
  Resolve(m, "da_webhook_add", m_api.webhook_add);
  Resolve(m, "da_webhook_delete", m_api.webhook_delete);
  Resolve(m, "da_webhook_test", m_api.webhook_test);
  Resolve(m, "da_notifications_since_json", m_api.notifications_since_json);
  Resolve(m, "da_remote_request_json", m_api.remote_request_json);
  Resolve(m, "da_core_init", m_api.core_init);
  Resolve(m, "da_browser_host_attach_v1", m_api.browser_host_attach_v1);
  Resolve(m, "da_browser_host_poll_v1", m_api.browser_host_poll_v1);
  Resolve(m, "da_browser_host_complete_v1", m_api.browser_host_complete_v1);
  Resolve(m, "da_browser_control_v1", m_api.browser_control_v1);
  Resolve(m, "da_process_control_v1", m_api.process_control_v1);
  Resolve(m, "da_core_shutdown", m_api.core_shutdown);
  Resolve(m, "da_core_version", m_api.core_version);
  Resolve(m, "da_build_identity_v1", m_api.build_identity_v1);
  Resolve(m, "da_last_error", m_api.last_error);
  Resolve(m, "da_string_free", m_api.string_free);

  Resolve(m, "da_order_submit_async", m_api.order_submit_async);
  Resolve(m, "da_order_submit_options_async", m_api.order_submit_options_async);
  Resolve(m, "da_order_replan_async", m_api.order_replan_async);
  Resolve(m, "da_order_from_issue_async", m_api.order_from_issue_async);
  Resolve(m, "da_issues_list_json", m_api.issues_list_json);
  Resolve(m, "da_issue_read_json", m_api.issue_read_json);
  Resolve(m, "da_issue_prompt_json", m_api.issue_prompt_json);
  Resolve(m, "da_issue_comment_json", m_api.issue_comment_json);
  Resolve(m, "da_order_from_issue_images_async",
          m_api.order_from_issue_images_async);
  Resolve(m, "da_order_submit_images_async", m_api.order_submit_images_async);
  Resolve(m, "da_order_attachments_json", m_api.order_attachments_json);
  Resolve(m, "da_vision_probe_json", m_api.vision_probe_json);
  Resolve(m, "da_order_answer_async", m_api.order_answer_async);
  Resolve(m, "da_order_plan_poll", m_api.order_plan_poll);
  Resolve(m, "da_plan_get_json", m_api.plan_get_json);
  Resolve(m, "da_order_plan_set_json", m_api.plan_set_json);
  Resolve(m, "da_plan_set_model", m_api.plan_set_model);
  Resolve(m, "da_exec_set_model", m_api.exec_set_model);
  Resolve(m, "da_exec_get_model", m_api.exec_get_model);
  Resolve(m, "da_audit_set_model", m_api.audit_set_model);
  Resolve(m, "da_audit_get_model", m_api.audit_get_model);
  Resolve(m, "da_swarm_set_models_json", m_api.swarm_set_models_json);
  Resolve(m, "da_swarm_get_models_json", m_api.swarm_get_models_json);
  Resolve(m, "da_order_preflight_json", m_api.order_preflight_json);
  Resolve(m, "da_external_agents_json", m_api.external_agents_json);
  Resolve(m, "da_doctor_json", m_api.doctor_json);
  Resolve(m, "da_update_state_json", m_api.update_state_json);
  Resolve(m, "da_update_check_json", m_api.update_check_json);
  Resolve(m, "da_update_download_json", m_api.update_download_json);
  Resolve(m, "da_update_set_enabled", m_api.update_set_enabled);
  Resolve(m, "da_project_rules_get_json", m_api.project_rules_get_json);
  Resolve(m, "da_project_rules_set", m_api.project_rules_set);
  Resolve(m, "da_cli_accounts_json", m_api.cli_accounts_json);
  Resolve(m, "da_cli_account_add", m_api.cli_account_add);
  Resolve(m, "da_cli_account_remove", m_api.cli_account_remove);
  Resolve(m, "da_cli_account_select", m_api.cli_account_select);
  Resolve(m, "da_update_set_apply_on_exit", m_api.update_set_apply_on_exit);
  Resolve(m, "da_update_pending_apply_json", m_api.update_pending_apply_json);
  Resolve(m, "da_external_agents_refresh", m_api.external_agents_refresh);
  Resolve(m, "da_external_paths_json", m_api.external_paths_json);
  Resolve(m, "da_external_paths_set", m_api.external_paths_set);
  Resolve(m, "da_external_model_options_set", m_api.external_model_options_set);
  Resolve(m, "da_external_limits_json", m_api.external_limits_json);
  Resolve(m, "da_external_limits_set", m_api.external_limits_set);
  Resolve(m, "da_repo_search", m_api.repo_search);
  Resolve(m, "da_embeddings_config_json", m_api.embeddings_config_json);
  Resolve(m, "da_embeddings_config_set", m_api.embeddings_config_set);
  Resolve(m, "da_repo_embed_index", m_api.repo_embed_index);
  Resolve(m, "da_repo_embed_status", m_api.repo_embed_status);
  Resolve(m, "da_embeddings_probe_json", m_api.embeddings_probe_json);
  Resolve(m, "da_set_direct_mode", m_api.set_direct_mode);
  Resolve(m, "da_get_direct_mode", m_api.get_direct_mode);
  Resolve(m, "da_set_deterministic_mode", m_api.set_deterministic_mode);
  Resolve(m, "da_get_deterministic_mode", m_api.get_deterministic_mode);
  Resolve(m, "da_role_set_model", m_api.role_set_model);
  Resolve(m, "da_role_models_json", m_api.role_models_json);
  Resolve(m, "da_swarm_set_enabled", m_api.swarm_set_enabled);
  Resolve(m, "da_swarm_get_enabled", m_api.swarm_get_enabled);
  Resolve(m, "da_composer_review_json", m_api.composer_review_json);
  Resolve(m, "da_plan_get_model", m_api.plan_get_model);

  Resolve(m, "da_order_approve", m_api.order_approve);
  Resolve(m, "da_order_dispatch_async", m_api.order_dispatch_async);
  Resolve(m, "da_order_resume_async", m_api.order_resume_async);
  Resolve(m, "da_order_set_expected", m_api.order_set_expected);
  Resolve(m, "da_order_expected_json", m_api.order_expected_json);
  Resolve(m, "da_order_dispatch_poll", m_api.order_dispatch_poll);
  Resolve(m, "da_order_cancel", m_api.order_cancel);
  Resolve(m, "da_plan_cancel", m_api.plan_cancel);
  Resolve(m, "da_order_status", m_api.order_status);
  Resolve(m, "da_order_events_json", m_api.order_events_json);
  Resolve(m, "da_set_agentic_max_iterations", m_api.set_agentic_max_iterations);
  Resolve(m, "da_get_agentic_max_iterations", m_api.get_agentic_max_iterations);
  Resolve(m, "da_ui_action_request", m_api.ui_action_request);
  Resolve(m, "da_ui_actions_poll", m_api.ui_actions_poll);
  Resolve(m, "da_ui_action_ack", m_api.ui_action_ack);
  Resolve(m, "da_onboarding_json", m_api.onboarding_json);
  Resolve(m, "da_onboarding_done", m_api.onboarding_done);

  Resolve(m, "da_sessions_json", m_api.sessions_json);
  Resolve(m, "da_sessions_json_filtered", m_api.sessions_json_filtered);
  Resolve(m, "da_session_archive", m_api.session_archive);
  Resolve(m, "da_session_archive_before_preview",
          m_api.session_archive_before_preview);
  Resolve(m, "da_session_archive_before", m_api.session_archive_before);
  Resolve(m, "da_session_messages_json", m_api.session_messages_json);
  Resolve(m, "da_session_messages_v2_json", m_api.session_messages_v2_json);
  Resolve(m, "da_session_rename", m_api.session_rename);
  Resolve(m, "da_session_delete", m_api.session_delete);
  Resolve(m, "da_list_artifacts_json", m_api.list_artifacts_json);

  Resolve(m, "da_provider_add", m_api.provider_add);
  Resolve(m, "da_providers_list_json", m_api.providers_list_json);
  Resolve(m, "da_key_add", m_api.key_add);
  Resolve(m, "da_key_remove", m_api.key_remove);
  Resolve(m, "da_keys_json", m_api.keys_json);
  Resolve(m, "da_key_set_meta", m_api.key_set_meta);
  Resolve(m, "da_models_list_json", m_api.models_list_json);
  Resolve(m, "da_models_selection_v1_json", m_api.models_selection_v1_json);
  Resolve(m, "da_model_preferences_set_v1_json",
          m_api.model_preferences_set_v1_json);
  Resolve(m, "da_models_discover", m_api.models_discover);
  Resolve(m, "da_model_register", m_api.model_register);
  Resolve(m, "da_model_prioritize", m_api.model_prioritize);
  Resolve(m, "da_catalog_info_json", m_api.catalog_info_json);
  Resolve(m, "da_router_candidates_json", m_api.router_candidates_json);

  Resolve(m, "da_health_summary_json", m_api.health_summary_json);
  Resolve(m, "da_health_detail_json", m_api.health_detail_json);
  Resolve(m, "da_health_probe_all_json", m_api.health_probe_all_json);
  Resolve(m, "da_usage_summary_json", m_api.usage_summary_json);
  Resolve(m, "da_usage_week_json", m_api.usage_week_json);
  Resolve(m, "da_budget_state_json", m_api.budget_state_json);
  Resolve(m, "da_budget_set_authorized", m_api.budget_set_authorized);
  Resolve(m, "da_inventory_json", m_api.inventory_json);
  Resolve(m, "da_inventory_refresh", m_api.inventory_refresh);

  Resolve(m, "da_audit_ledger_json", m_api.audit_ledger_json);
  Resolve(m, "da_audit_checklist_json", m_api.audit_checklist_json);
  Resolve(m, "da_ledger_escalations_json", m_api.ledger_escalations_json);
  Resolve(m, "da_approval_pending_json", m_api.approval_pending_json);
  Resolve(m, "da_approval_resolve", m_api.approval_resolve);
  Resolve(m, "da_set_permission_config", m_api.set_permission_config);
  Resolve(m, "da_get_permission_config", m_api.get_permission_config);
  Resolve(m, "da_set_hooks_config", m_api.set_hooks_config);
  Resolve(m, "da_set_governance_mode", m_api.set_governance_mode);
  Resolve(m, "da_get_governance_mode", m_api.get_governance_mode);
  Resolve(m, "da_set_reasoning_effort", m_api.set_reasoning_effort);
  Resolve(m, "da_approval_resolve_scoped", m_api.approval_resolve_scoped);
  Resolve(m, "da_specialists_json", m_api.specialists_json);
  Resolve(m, "da_model_scores_json", m_api.model_scores_json);
  Resolve(m, "da_evolution_summary_json", m_api.evolution_summary_json);

  Resolve(m, "da_set_workspace_root", m_api.set_workspace_root);
  Resolve(m, "da_mounts_list_json", m_api.mounts_list_json);
  Resolve(m, "da_mount_add", m_api.mount_add);
  Resolve(m, "da_mount_remove", m_api.mount_remove);
  Resolve(m, "da_mcp_connect", m_api.mcp_connect);
  Resolve(m, "da_mcp_disconnect", m_api.mcp_disconnect);
  Resolve(m, "da_mcp_is_connected", m_api.mcp_is_connected);
  Resolve(m, "da_mcp_tools_json", m_api.mcp_tools_json);
  Resolve(m, "da_mcp_call_tool", m_api.mcp_call_tool);
  Resolve(m, "da_mcp_auth_token", m_api.mcp_auth_token);
  Resolve(m, "da_memory_context_json", m_api.memory_context_json);
  Resolve(m, "da_skills_discover_json", m_api.skills_discover_json);
  Resolve(m, "da_model_set_favorite", m_api.model_set_favorite);
  Resolve(m, "da_web_search", m_api.web_search);
  Resolve(m, "da_capture_screenshot", m_api.capture_screenshot);
  Resolve(m, "da_spaces_list_json", m_api.spaces_list_json);
  Resolve(m, "da_space_create", m_api.space_create);
  Resolve(m, "da_space_archive", m_api.space_archive);
  Resolve(m, "da_spaces_prune", m_api.spaces_prune);
  Resolve(m, "da_worktree_config_json", m_api.worktree_config_json);
  Resolve(m, "da_order_ship_json", m_api.order_ship_json);
  Resolve(m, "da_git_store_credential", m_api.git_store_credential);
  Resolve(m, "da_pr_merge", m_api.pr_merge);
  Resolve(m, "da_prs_json", m_api.prs_json);
  Resolve(m, "da_repo_clone", m_api.repo_clone);
  Resolve(m, "da_order_worktree_json", m_api.order_worktree_json);
  Resolve(m, "da_plugins_list_json", m_api.plugins_list_json);
  Resolve(m, "da_plugin_trust", m_api.plugin_trust);
  Resolve(m, "da_plugin_untrust", m_api.plugin_untrust);
  Resolve(m, "da_plugins_dir", m_api.plugins_dir);
  Resolve(m, "da_complete_text", m_api.complete_text);
  // E5.18: Best-of-N.
  Resolve(m, "da_order_set_best_of_n", m_api.order_set_best_of_n);
  Resolve(m, "da_best_of_n_candidates_json", m_api.best_of_n_candidates_json);
  Resolve(m, "da_best_of_n_choose", m_api.best_of_n_choose);
}

bool CoreClient::SetWorkspaceRoot(const std::wstring &root,
                                  std::string &error) {
  if (!m_coreEngineHandle || !m_api.set_workspace_root) {
    error = "El motor no está disponible.";
    return false;
  }
  const auto utf8 = WideToUtf8Local(root);
  const auto result =
      Wrap(m_api.set_workspace_root(m_coreEngineHandle, utf8.c_str()));
  error = result.error;
  return result.ok();
}

CoreClient::CoreClient(InitMode mode) {
  // Unit-test seam: no path lookup, database, DLL or child process.
  if (mode == InitMode::isolated_empty)
    return;
  std::wstring dataDir = UserDataDir();
  m_dataDirectory = dataDir;
  if (dataDir.empty()) {
    m_initError = "La carpeta de datos no esta disponible o no se pudo "
                  "proteger con permisos exclusivos del usuario.";
    return;
  }
  std::wstring runtimeDb = dataDir + L"\\runtime.db";
  m_runtimeDbPath = WideToUtf8Local(runtimeDb);
  m_governanceFilePath = dataDir + L"\\governance.txt";
  LoadGovernanceMode();

  wchar_t hostPath[MAX_PATH];
  if (GetModuleFileNameW(nullptr, hostPath, MAX_PATH) == 0) {
    m_initError = "No se pudo determinar la ruta del ejecutable de la cabina.";
    return;
  }

  wchar_t *lastSlash = wcsrchr(hostPath, L'\\');
  std::wstring exeDir =
      lastSlash ? std::wstring(hostPath, lastSlash - hostPath + 1) : L".\\";
  std::wstring dllPath = exeDir + L"devagents_core.dll";

  // si la DLL falta o está dañada, Windows abriría un diálogo modal
  // («Imagen incorrecta») antes de que la cabina pueda explicar el error.
  // Supresión solo en este hilo y solo durante la carga; si no se puede
  // activar, no se carga y se informa.
  DWORD oldErrorMode = 0;
  if (!SetThreadErrorMode(GetThreadErrorMode() | SEM_FAILCRITICALERRORS |
                              SEM_NOOPENFILEERRORBOX,
                          &oldErrorMode)) {
    m_lastError = GetLastError();
    m_initError = "No se pudo preparar la carga de devagents_core.dll (error " +
                  std::to_string(m_lastError) + ").";
    return;
  }
  m_hCoreDll = LoadLibraryW(dllPath.c_str());
  const DWORD loadError = GetLastError();
  if (!SetThreadErrorMode(oldErrorMode, nullptr)) {
    // Si no se puede restaurar, el hilo conserva la supresión (sin
    // diálogos), que es el lado seguro; se deja rastro para diagnóstico.
    OutputDebugStringW(L"DevAgents: no se pudo restaurar el modo de error del "
                       L"hilo tras cargar devagents_core.dll\n");
  }
  SetLastError(loadError);
  if (!m_hCoreDll) {
    m_lastError = GetLastError();
    m_initError = "No se pudo cargar devagents_core.dll (error " +
                  std::to_string(m_lastError) + ").";
    return;
  }

  ResolveApi();
  const char *identity =
      m_api.build_identity_v1 ? m_api.build_identity_v1() : nullptr;
  m_initError = versions::Mismatch("motor DLL", identity ? identity : "");
  // Block before core_init: a mixed C ABI may corrupt memory or user data.
  if (!m_initError.empty()) {
    std::cerr << "[CK-COMP-004] " << m_initError << std::endl;
    OutputDebugStringA((m_initError + "\n").c_str());
    CreateDirectoryW((m_dataDirectory + L"\\logs").c_str(), nullptr);
    std::ofstream log(std::filesystem::path(m_dataDirectory) / L"logs" /
                          L"version.log",
                      std::ios::app);
    if (log)
      log << m_initError << '\n';
    else
      OutputDebugStringA("CK-COMP-004: no se pudo abrir version.log\n");
    const int length =
        MultiByteToWideChar(CP_UTF8, 0, m_initError.c_str(), -1, nullptr, 0);
    std::wstring warning(length > 0 ? length : 1, L'\0');
    if (length > 0)
      MultiByteToWideChar(CP_UTF8, 0, m_initError.c_str(), -1, warning.data(),
                          length);
    themed::Show(nullptr, L"Versión incompatible", warning, themed::Kind::error,
                 themed::Buttons::ok);
    return;
  }
  if (!m_api.core_init) {
    m_initError = "devagents_core.dll no exporta da_core_init.";
    return;
  }

  int rc = m_api.core_init(&m_coreEngineHandle, m_runtimeDbPath.c_str());
  if (rc != 0 || m_coreEngineHandle == nullptr) {
    m_coreEngineHandle = nullptr;
    std::string detail = LastEngineError();
    m_initError = detail.empty()
                      ? ("da_core_init fallo con codigo " + std::to_string(rc))
                      : detail;
    std::cout << "[DEVAGENTS_CORE] init error: " << m_initError << std::endl;
    return;
  }

  // FUENTE ÚNICA (E1.12): `settings.governance_mode` del catálogo manda. El
  // governance.txt que leyó LoadGovernanceMode antes de core_init era solo una
  // pre-carga para pintar el estado; aquí, con el motor ya vivo, la DB gana y
  // el espejo se reescribe si difiere — nunca al revés.
  if (m_api.get_governance_mode) {
    char *mode_str = nullptr;
    if (m_api.get_governance_mode(m_coreEngineHandle, &mode_str) == 0 &&
        mode_str) {
      std::string v = TakeString(mode_str);
      if (v == "free" || v == "paid" || v == "hybrid" || v == "local" ||
          v == "local_only" || v == "free_tier_first" ||
          v == "paid_tier_first") {
        if (v != m_governanceMode) {
          m_governanceMode = v;
          // Reescribe el espejo para que el próximo arranque precargue el valor
          // de la fuente real, no uno viejo.
          HANDLE h = CreateFileW(m_governanceFilePath.c_str(), GENERIC_WRITE, 0,
                                 nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL,
                                 nullptr);
          if (h != INVALID_HANDLE_VALUE) {
            DWORD written = 0;
            WriteFile(h, v.c_str(), (DWORD)v.size(), &written, nullptr);
            CloseHandle(h);
          }
        }
      }
    }
  }
}

CoreClient::~CoreClient() {
  StopCoreProcess();
  if (m_engineSupervisorStarted)
    m_engineSupervisor.Stop();
}

void CoreClient::LoadGovernanceMode() {
  HANDLE h =
      CreateFileW(m_governanceFilePath.c_str(), GENERIC_READ, FILE_SHARE_READ,
                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return;
  char buf[32] = {};
  DWORD read = 0;
  if (ReadFile(h, buf, sizeof(buf) - 1, &read, nullptr) && read > 0) {
    std::string v(buf, read);
    while (!v.empty() &&
           (v.back() == '\n' || v.back() == '\r' || v.back() == ' '))
      v.pop_back();
    if (v == "free" || v == "paid" || v == "hybrid" || v == "local" ||
        v == "local_only" || v == "free_tier_first" || v == "paid_tier_first")
      m_governanceMode = v;
  }
  CloseHandle(h);
}

bool CoreClient::SetGovernanceMode(const std::string &mode) {
  if (mode != "free" && mode != "paid" && mode != "hybrid" && mode != "local" &&
      mode != "local_only" && mode != "free_tier_first" &&
      mode != "paid_tier_first")
    return false;
  m_governanceMode = mode;

  // Lo IMPORTANTE es esto: el router lee `settings.governance_mode` del
  // catálogo, no este archivo. Antes solo se escribía el .txt, así que elegir
  // "Prioriza pago" cambiaba la etiqueta de la barra de estado y nada más — el
  // ruteo seguía en hybrid, con los modelos gratuitos por delante. El archivo
  // se conserva como espejo para poder pintar el estado sin llamar al motor.
  if (m_api.set_governance_mode && m_coreEngineHandle) {
    m_api.set_governance_mode(m_coreEngineHandle, mode.c_str());
  }

  HANDLE h =
      CreateFileW(m_governanceFilePath.c_str(), GENERIC_WRITE, 0, nullptr,
                  CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return false;
  DWORD written = 0;
  WriteFile(h, mode.c_str(), (DWORD)mode.size(), &written, nullptr);
  CloseHandle(h);
  return true;
}

std::string CoreClient::TakeString(char *s) const {
  if (!s)
    return "";
  std::string out(s);
  if (m_api.string_free)
    m_api.string_free(s);
  return out;
}

std::string CoreClient::LastEngineError() const {
  if (!m_api.last_error)
    return "";
  char *msg = nullptr;
  if (m_api.last_error(&msg) != 0 || !msg)
    return "";
  return TakeString(msg);
}

CoreResult CoreClient::Wrap(int rc) const {
  CoreResult res;
  res.rc = rc;
  if (rc != 0)
    res.error = LastEngineError();
  return res;
}

CoreResult CoreClient::CallJson(int (*fn)(void *, char **)) const {
  CoreResult res;
  if (!fn) {
    res.error =
        "La funcion solicitada no esta disponible en devagents_core.dll";
    return res;
  }
  if (!m_coreEngineHandle) {
    res.error =
        m_initError.empty() ? "El motor no esta inicializado" : m_initError;
    return res;
  }
  char *out = nullptr;
  res.rc = fn(m_coreEngineHandle, &out);
  res.json = TakeString(out);
  if (res.rc != 0)
    res.error = LastEngineError();
  return res;
}

CoreResult CoreClient::CallJson(int (*fn)(void *, const char *, char **),
                                const std::string &arg_json) const {
  CoreResult res;
  if (!fn) {
    res.error =
        "La funcion solicitada no esta disponible en devagents_core.dll";
    return res;
  }
  if (!m_coreEngineHandle) {
    res.error =
        m_initError.empty() ? "El motor no esta inicializado" : m_initError;
    return res;
  }
  char *out = nullptr;
  res.rc = fn(m_coreEngineHandle, arg_json.c_str(), &out);
  res.json = TakeString(out);
  if (res.rc != 0)
    res.error = LastEngineError();
  return res;
}

bool CoreClient::StartCoreProcess() {
  wchar_t hostPath[MAX_PATH];
  if (GetModuleFileNameW(nullptr, hostPath, MAX_PATH) == 0) {
    m_lastError = GetLastError();
    m_isSupervised = false;
    return false;
  }

  wchar_t *lastSlash = wcsrchr(hostPath, L'\\');
  std::wstring exeDir =
      lastSlash ? std::wstring(hostPath, lastSlash - hostPath + 1) : L".\\";
  m_coreExePath = exeDir + L"devagents-core.exe";

  STARTUPINFOW si = {sizeof(STARTUPINFOW)};
  PROCESS_INFORMATION pi = {};

  std::wstring fullCmd = L"\"" + m_coreExePath + L"\" --supervised";
  std::vector<wchar_t> cmdBuffer(fullCmd.begin(), fullCmd.end());
  cmdBuffer.push_back(L'\0');

  if (CreateProcessW(m_coreExePath.c_str(), cmdBuffer.data(), nullptr, nullptr,
                     FALSE, CREATE_NO_WINDOW, nullptr, exeDir.c_str(), &si,
                     &pi)) {
    m_hProcess = pi.hProcess;
    m_dwPid = pi.dwProcessId;
    CloseHandle(pi.hThread);
    m_isSupervised = true;
    m_lastError = 0;
    std::cout << "[DEVAGENTS_CORE] Started process PID: " << m_dwPid
              << std::endl;
    return true;
  }

  m_lastError = GetLastError();
  std::cout << "[DEVAGENTS_CORE] CreateProcessW failed with err: "
            << m_lastError << std::endl;
  m_hProcess = nullptr;
  m_dwPid = 0;
  m_isSupervised = false;
  return false;
}

void CoreClient::StopCoreProcess() {
  if (m_browserStopHook)
    m_browserStopHook();
  if (m_remoteStopHook)
    m_remoteStopHook();
  if (m_hProcess) {
    TerminateProcess(m_hProcess, 0);
    CloseHandle(m_hProcess);
    m_hProcess = nullptr;
  }
  if (m_hCoreDll && m_coreEngineHandle) {
    if (m_api.core_shutdown)
      m_api.core_shutdown(m_coreEngineHandle);
    m_coreEngineHandle = nullptr;
  }
  if (m_hCoreDll) {
    FreeLibrary(m_hCoreDll);
    m_hCoreDll = nullptr;
    m_api = CoreApi{};
  }
  m_dwPid = 0;
  m_isSupervised = false;
}

bool CoreClient::RestartCoreProcess() {
  StopCoreProcess();
  return StartCoreProcess();
}

void CoreClient::CheckProcessHealth() {
  if (m_isSupervised && m_hProcess) {
    DWORD exitCode = 0;
    if (GetExitCodeProcess(m_hProcess, &exitCode)) {
      if (exitCode != STILL_ACTIVE) {
        CloseHandle(m_hProcess);
        m_hProcess = nullptr;
        m_dwPid = 0;
        m_isSupervised = false;
        // Re-start automatically on crash
        StartCoreProcess();
      }
    }
  }
}

CoreStatus CoreClient::GetStatus() const {
  CoreClient *self = const_cast<CoreClient *>(this);
  self->CheckProcessHealth();

  CoreStatus status;
  // D4 tramo 2: da_status va por el HIJO devagents-engine.exe (con
  // reconexión si murió). El tramo 1 lo demostró en banco; este es el cable
  // en la cabina. Si el supervisor no puede arrancar (binario ausente en
  // una instalación vieja), se cae al PID del host con el mismo formato que
  // antes — la cabina no se queda sin estado.
  if (!m_engineSupervisorStarted) {
    wchar_t hostPath[MAX_PATH];
    if (GetModuleFileNameW(nullptr, hostPath, MAX_PATH) != 0) {
      wchar_t *lastSlash = wcsrchr(hostPath, L'\\');
      std::wstring exeDir =
          lastSlash ? std::wstring(hostPath, lastSlash - hostPath + 1) : L".\\";
      char pidBuf[32] = {};
      sprintf_s(pidBuf, sizeof(pidBuf), "%lu", GetCurrentProcessId());
      // La tubería lleva el PID del host: dos cabinas abiertas no se roban
      // el nombre.
      std::string pipe = std::string("devagents-engine-") + pidBuf;
      self->m_engineSupervisorStarted = self->m_engineSupervisor.Start(
          exeDir + L"devagents-engine.exe", pipe);
    }
  }
  if (m_engineSupervisorStarted) {
    EngineSupervisor::StatusResult r = self->m_engineSupervisor.Status();
    if (r.online) {
      status.running = true;
      status.engineReady = true;
      status.pid = r.pid; // el PID del HIJO, no el de la cabina
      status.version = r.version;
    } else {
      status.running = false;
      status.engineReady = false;
      status.initError = r.error;
    }
  } else {
    // Sin supervisor: el motor corre DENTRO de este proceso (DLL in-proc).
    status.running = EngineReady();
    status.engineReady = EngineReady();
    status.pid = GetCurrentProcessId();
    status.lastError = m_lastError;
    status.initError = m_initError;
  }
  status.coreHandle = m_coreEngineHandle;
  status.lastError = m_lastError;
  status.governanceMode = m_governanceMode;
  // la version de producto la publica el propio motor
  // (da_core_version). Se resuelve para LAS DOS rutas —supervisor y DLL
  // in-proc—: antes este bloque estaba condicionado a
  // `m_engineSupervisorStarted`, asi que cuando el motor corria in-proc
  // `version` quedaba vacia y el Monitor pintaba «—» mientras la barra de
  // estado seguia enseñando su valor por defecto. Una sola resolucion, sin
  // inventar el dato ni duplicar la logica.
  if (status.version.empty() && m_api.core_version) {
    const char *ver = m_api.core_version();
    if (ver && ver[0] != '\0')
      status.version = ver;
  }

  if (!m_coreEngineHandle)
    return status;

  // QA 10-nov: el modelo que TRABAJA es el del ejecutor (Directo usa ese;
  // Orquestado ejecuta con el). Antes se mostraba solo el del planificador y
  // la barra decia «qwen2.5:7b» mientras respondia OpenCode. Si el ejecutor
  // no esta fijado, se cae al planificador como antes.
  if (m_api.exec_get_model) {
    const char *prov = nullptr;
    const char *model = nullptr;
    if (m_api.exec_get_model(m_coreEngineHandle, &prov, &model) == 0) {
      if (prov) {
        if (prov[0] != '\0')
          status.activeProvider = prov;
        if (m_api.string_free)
          m_api.string_free(const_cast<char *>(prov));
      }
      if (model) {
        if (model[0] != '\0')
          status.activeModel = model;
        if (m_api.string_free)
          m_api.string_free(const_cast<char *>(model));
      }
    }
  }
  // Modelo de planificacion forzado, si el usuario fijo uno. Sin forzar, el
  // router elige por tarea y no hay un unico "modelo activo" que mostrar.
  if (status.activeModel.empty() && m_api.plan_get_model) {
    const char *prov = nullptr;
    const char *model = nullptr;
    if (m_api.plan_get_model(m_coreEngineHandle, &prov, &model) == 0) {
      if (prov) {
        status.activeProvider = prov;
        if (m_api.string_free)
          m_api.string_free(const_cast<char *>(prov));
      }
      if (model) {
        status.activeModel = model;
        if (m_api.string_free)
          m_api.string_free(const_cast<char *>(model));
      }
    }
  }
  if (status.activeModel.empty())
    status.activeModel = "auto (router)";

  // Recuento de claves y proveedores a partir del catalogo real. Se cuenta
  // sobre el JSON sin parsearlo del todo: basta con contar objetos.
  auto countObjects = [](const std::string &json) {
    int depth = 0;
    int count = 0;
    bool inStr = false;
    bool esc = false;
    for (char c : json) {
      if (esc) {
        esc = false;
        continue;
      }
      if (inStr) {
        if (c == '\\')
          esc = true;
        else if (c == '"')
          inStr = false;
        continue;
      }
      if (c == '"')
        inStr = true;
      else if (c == '{') {
        if (depth == 0)
          count++;
        depth++;
      } else if (c == '}')
        depth--;
    }
    return count;
  };

  CoreResult keys = CallJson(m_api.keys_json);
  if (keys.ok())
    status.keyCount = countObjects(keys.json);
  CoreResult provs = CallJson(m_api.providers_list_json);
  if (provs.ok())
    status.providerCount = countObjects(provs.json);

  status.keyLabel = status.keyCount > 0
                        ? (std::to_string(status.keyCount) + " clave(s)")
                        : "sin claves";

  return status;
}

} // namespace beats
