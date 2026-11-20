/* inspect installed PE metadata without loading any product DLL.
 */
#define WIN32_LEAN_AND_MEAN
#include "build_version.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

int da_read_component_version(const wchar_t *path, char *output,
                              unsigned int capacity) {
  DWORD ignored = 0;
  DWORD size = GetFileVersionInfoSizeW(path, &ignored);
  if (!size || size > 1024 * 1024 || !capacity)
    return 0;
  void *data = malloc(size);
  if (!data)
    return 0;
  int ok = 0;
  wchar_t *value = NULL;
  UINT length = 0;
  if (GetFileVersionInfoW(path, 0, size, data) &&
      VerQueryValueW(data, L"\\StringFileInfo\\040904b0\\ProductVersion",
                     (void **)&value, &length) &&
      length > 1 && length <= 256) {
    ok = WideCharToMultiByte(CP_UTF8, 0, value, -1, output, capacity, NULL,
                             NULL) > 0;
  }
  free(data);
  return ok;
}

static void print_piece(FILE *report, const wchar_t *directory,
                        const wchar_t *file, const char *piece) {
  wchar_t path[32768];
  char version[1024];
  if (swprintf(path, 32768, L"%ls%ls", directory, file) < 0) {
    fprintf(report, "%s: ruta demasiado larga\n", piece);
    return;
  }
  fprintf(report, "%s: %s\n", piece,
          da_read_component_version(path, version, sizeof(version))
              ? version
              : "ausente o sin version (actualiza esta pieza)");
}

void da_write_installed_versions(FILE *report, const wchar_t *directory) {
  fprintf(report, "DevAgents CLI: %s\n", DA_BUILD_IDENTITY);
  print_piece(report, directory, L"devagents-host.exe", "host");
  print_piece(report, directory, L"devagents_core.dll", "motor DLL");
  print_piece(report, directory, L"devagents-mcp.exe", "MCP");
  wchar_t manifest[32768];
  if (swprintf(manifest, 32768, L"%lsshell\\webui\\dist\\version.json",
               directory) < 0) {
    fprintf(report, "WebUI: ruta demasiado larga\n");
    return;
  }
  FILE *file = _wfopen(manifest, L"rb");
  char json[4097];
  size_t size = file ? fread(json, 1, sizeof(json) - 1, file) : 0;
  int valid = file && !ferror(file) && size < sizeof(json) - 1;
  if (file)
    fclose(file);
  json[size] = '\0';
  /* Our packaged manifest has a canonical, compact JSON encoding. */
  char *identity = valid ? strstr(json, "\"identity\":\"") : NULL;
  char *end = identity ? strchr(identity + 12, '"') : NULL;
  if (identity && end) {
    *end = '\0';
    fprintf(report, "WebUI empaquetada: %s\n", identity + 12);
  } else {
    fprintf(
        report,
        "WebUI empaquetada: ausente o sin version (actualiza esta pieza)\n");
  }
}

void da_print_installed_versions(void) {
  wchar_t directory[32768];
  DWORD length = GetModuleFileNameW(NULL, directory, 32768);
  if (!length || length >= 32768) {
    fprintf(stdout, "No se pudo resolver el directorio instalado.\n");
    return;
  }
  wchar_t *slash = wcsrchr(directory, L'\\');
  if (!slash) {
    fprintf(stdout, "No se pudo resolver el directorio instalado.\n");
    return;
  }
  slash[1] = L'\0';
  da_write_installed_versions(stdout, directory);
}
