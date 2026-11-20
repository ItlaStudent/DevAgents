//! Raíz de la biblioteca dinámica beats_core.dll (T-F7-02).
//!
//! Al construir core como DLL, Zig elimina por GC las `export fn` de c_api.zig
//! porque nada las referencia internamente (no hay un `main`). Este root toma
//! la dirección de cada función de la API C para forzar su codegen y, junto con
//! shell/host/beats_core.def, exportarlas en la tabla de exports del DLL.
const core = @import("core");

comptime {
    _ = &core.c_api.da_models_selection_v1_json;
    _ = &core.c_api.da_model_preferences_set_v1_json;
    _ = &core.c_api.da_build_identity_v1;
    _ = &core.c_api.da_webhook_list_json;
    _ = &core.c_api.da_webhook_add;
    _ = &core.c_api.da_webhook_delete;
    _ = &core.c_api.da_webhook_test;
    _ = &core.c_api.da_notifications_since_json;
    _ = &core.c_api.da_remote_request_json;
    _ = &core.c_api.da_core_init;
    _ = &core.c_api.da_core_shutdown;
    _ = &core.c_api.da_order_submit;
    _ = &core.c_api.da_order_submit_options_async;
    _ = &core.c_api.da_order_replan_async;
    _ = &core.c_api.da_order_plan_json;
    _ = &core.c_api.da_order_from_issue_async;
    _ = &core.c_api.da_order_from_issue_images_async;
    _ = &core.c_api.da_issues_list_json;
    _ = &core.c_api.da_issue_read_json;
    _ = &core.c_api.da_issue_prompt_json;
    _ = &core.c_api.da_issue_comment_json;
    _ = &core.c_api.da_order_answer;
    _ = &core.c_api.da_order_approve;
    _ = &core.c_api.da_order_confirm_json;
    _ = &core.c_api.da_order_cancel;
    _ = &core.c_api.da_order_status;
    _ = &core.c_api.da_sessions_json;
    _ = &core.c_api.da_session_messages_json;
    _ = &core.c_api.da_session_messages_v2_json;
    _ = &core.c_api.da_session_rename;
    _ = &core.c_api.da_plan_get_json;
    _ = &core.c_api.da_models_list_json;
    _ = &core.c_api.da_worker_output_poll;
    _ = &core.c_api.da_order_events_json;
    _ = &core.c_api.da_memory_context_json;
    _ = &core.c_api.da_approval_pending_json;
    _ = &core.c_api.da_approval_resolve;
    _ = &core.c_api.da_last_error;
    _ = &core.c_api.da_string_free;
    _ = &core.c_api.da_core_version;
    _ = &core.c_api.da_provider_add;
    _ = &core.c_api.da_key_add;
    _ = &core.c_api.da_model_register;
    _ = &core.c_api.da_models_discover;
    _ = &core.c_api.da_mount_add;
    _ = &core.c_api.da_mounts_list_json;
    _ = &core.c_api.da_skills_discover_json;
    _ = &core.c_api.da_shell_run;
    _ = &core.c_api.da_health_detail_json;
    _ = &core.c_api.da_health_probe_all_json;
    _ = &core.c_api.da_providers_list_json;
    _ = &core.c_api.da_catalog_info_json;
    _ = &core.c_api.da_specialists_json;
    _ = &core.c_api.da_router_candidates_json;
    _ = &core.c_api.da_ledger_escalations_json;
    _ = &core.c_api.da_checklist_json;
    _ = &core.c_api.da_mcp_connect;
    _ = &core.c_api.da_mcp_disconnect;
    _ = &core.c_api.da_mcp_is_connected;
    _ = &core.c_api.da_mcp_tools_json;
    _ = &core.c_api.da_mcp_call_tool;
    _ = &core.c_api.da_set_agentic_max_iterations;
    _ = &core.c_api.da_set_direct_mode;
    _ = &core.c_api.da_get_direct_mode;
    _ = &core.c_api.da_set_deterministic_mode;
    _ = &core.c_api.da_get_deterministic_mode;
    _ = &core.c_api.da_role_set_model;
    _ = &core.c_api.da_role_models_json;
    _ = &core.c_api.da_swarm_set_enabled;
    _ = &core.c_api.da_swarm_get_enabled;
    _ = &core.c_api.da_composer_review_json;
    // E5.15 (A-a): índice vectorial persistente + probe de embeddings.
    _ = &core.c_api.da_repo_embed_index;
    _ = &core.c_api.da_repo_embed_status;
    _ = &core.c_api.da_embeddings_probe_json;
}
