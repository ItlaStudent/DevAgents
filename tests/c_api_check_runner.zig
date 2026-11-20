const std = @import("std");
const core = @import("core");

extern "c" fn c_api_test_main() c_int;

pub fn main() !void {
    _ = core;
    // Frontera C-ABI completa (gaps de cobertura FIX D.3).
    _ = &core.c_api.da_core_init;
    _ = &core.c_api.da_core_shutdown;
    _ = &core.c_api.da_core_version;
    _ = &core.c_api.da_order_submit;
    _ = &core.c_api.da_order_answer;
    _ = &core.c_api.da_order_approve;
    _ = &core.c_api.da_order_confirm_json;
    _ = &core.c_api.da_order_status;
    _ = &core.c_api.da_plan_get_json;
    _ = &core.c_api.da_models_list_json;
    _ = &core.c_api.da_worker_output_poll;
    _ = &core.c_api.da_shell_run;
    _ = &core.c_api.da_order_events_json;
    _ = &core.c_api.da_sessions_json;
    _ = &core.c_api.da_health_summary_json;
    _ = &core.c_api.da_health_detail_json;
    _ = &core.c_api.da_health_probe_all_json;
    _ = &core.c_api.da_providers_list_json;
    _ = &core.c_api.da_router_candidates_json;
    _ = &core.c_api.da_ledger_escalations_json;
    _ = &core.c_api.da_checklist_json;
    _ = &core.c_api.da_memory_context_json;
    _ = &core.c_api.da_approval_pending_json;
    _ = &core.c_api.da_approval_resolve;
    _ = &core.c_api.da_string_free;
    _ = &core.c_api.da_last_error;

    const code = c_api_test_main();
    if (code != 0) {
        std.process.exit(1);
    }
}
