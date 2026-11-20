#include "da_plugin.h"

const char *da_version_string(void) { return "0.1.0"; }

static const da_capability_t da_builtin_caps[] = {
    {.kind = DA_CAP_PROVIDER,
     .name = "plugin_abi",
     .description = "DevAgents plugin ABI provider"},
};

da_result_t da_plugin_get_info(da_plugin_info_t *out_info) {
  if (out_info == NULL) {
    return DA_ERR_INVALID;
  }
  out_info->size = sizeof(da_plugin_info_t);
  out_info->abi_version = DA_ABI_VERSION;
  out_info->name = "devagents_plugin_abi";
  out_info->version = "0.1.0";
  out_info->capability_count =
      sizeof(da_builtin_caps) / sizeof(da_capability_t);
  out_info->capabilities = da_builtin_caps;
  return DA_OK;
}
