#ifndef DA_PLUGIN_H
#define DA_PLUGIN_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>

#define DA_VERSION_MAJOR 0
#define DA_VERSION_MINOR 1
#define DA_VERSION_PATCH 0

#define DA_ABI_VERSION 1

typedef enum {
  DA_OK = 0,
  DA_ERR_INVALID = 1,
  DA_ERR_OOM = 2,
} da_result_t;

typedef enum {
  DA_CAP_PROVIDER = 1,
  DA_CAP_TOOL = 2,
  DA_CAP_SKILL = 3,
  DA_CAP_MCP = 4,
} da_capability_kind_t;

typedef struct {
  da_capability_kind_t kind;
  const char *name;
  const char *description;
} da_capability_t;

typedef struct {
  size_t size;
  uint32_t abi_version;
  const char *name;
  const char *version;
  size_t capability_count;
  const da_capability_t *capabilities;
} da_plugin_info_t;

const char *da_version_string(void);
da_result_t da_plugin_get_info(da_plugin_info_t *out_info);

#ifdef __cplusplus
}
#endif

#endif
