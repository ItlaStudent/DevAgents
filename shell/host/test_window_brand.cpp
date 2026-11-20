#include "window.hpp"
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <initializer_list>
#include <shellapi.h>
#include <shobjidl.h>

static int checks = 0;
static int failures = 0;

static bool Expect(bool ok, const char *name) {
  ++checks;
  if (!ok)
    ++failures;
  std::printf("[%s] %s\n", ok ? "PASS" : "FAIL", name);
  return ok;
}

static unsigned short Read16(const unsigned char *bytes) {
  unsigned short value;
  std::memcpy(&value, bytes, sizeof(value));
  return value;
}

static void CheckExecutableResource(const wchar_t *path) {
  HMODULE exe = LoadLibraryExW(
      path, nullptr, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
  if (!Expect(exe != nullptr, "host loaded as resource only (not executed)"))
    return;
  HRSRC group = FindResourceW(exe, MAKEINTRESOURCEW(1), RT_GROUP_ICON);
  if (Expect(group != nullptr, "host embeds brand icon group 1")) {
    const DWORD size = SizeofResource(exe, group);
    HGLOBAL loaded = LoadResource(exe, group);
    const auto *bytes =
        static_cast<const unsigned char *>(LockResource(loaded));
    if (Expect(bytes && size >= 6, "icon group bytes readable")) {
      const unsigned short count = Read16(bytes + 4);
      if (Expect(Read16(bytes) == 0 && Read16(bytes + 2) == 1 && count > 0 &&
                     size == 6u + 14u * count,
                 "icon group bounds valid")) {
        for (unsigned target : {16u, 24u, 32u, 48u, 64u, 256u}) {
          bool found = false;
          for (unsigned i = 0; i < count; ++i) {
            const auto *entry = bytes + 6 + 14 * i;
            if ((entry[0] ? entry[0] : 256u) != target ||
                (entry[1] ? entry[1] : 256u) != target)
              continue;
            HRSRC icon = FindResourceW(
                exe, MAKEINTRESOURCEW(Read16(entry + 12)), RT_ICON);
            DWORD expected = 0;
            std::memcpy(&expected, entry + 8, sizeof(expected));
            found =
                icon && expected > 0 && SizeofResource(exe, icon) == expected;
          }
          char name[80];
          std::snprintf(name, sizeof(name),
                        "host icon %u x %u embedded with valid payload", target,
                        target);
          Expect(found, name);
        }
      }
    }
  }
  Expect(FreeLibrary(exe) != FALSE, "host resource module released");
}

static void CheckWindow(HWND hwnd, const char *name) {
  Expect(hwnd && GetClassLongPtrW(hwnd, GCLP_HICON) != 0, name);
  Expect(hwnd && GetClassLongPtrW(hwnd, GCLP_HICONSM) != 0,
         "window class registers small icon");
  Expect(hwnd && static_cast<ULONG_PTR>(
                     SendMessageW(hwnd, WM_GETICON, ICON_BIG, 0)) ==
                     GetClassLongPtrW(hwnd, GCLP_HICON),
         "window WM_SETICON big matches class brand");
  Expect(hwnd && static_cast<ULONG_PTR>(
                     SendMessageW(hwnd, WM_GETICON, ICON_SMALL, 0)) ==
                     GetClassLongPtrW(hwnd, GCLP_HICONSM),
         "window WM_SETICON small matches class brand");
}

int main() {
  int argc = 0;
  wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!Expect(argv && argc == 2,
              "one built host executable argument required")) {
    if (argv)
      LocalFree(argv);
    return 1;
  }
  CheckExecutableResource(argv[1]);
  LocalFree(argv);

  beats::Window invalid;
  Expect(!invalid.Create(nullptr, L"invalid", 320, 240) &&
             GetLastError() == ERROR_INVALID_PARAMETER,
         "null resource instance rejected explicitly");
  HMODULE missing = LoadLibraryW(L"kernel32.dll");
  Expect(missing != nullptr, "missing-icon fixture module loaded");
  if (missing) {
    beats::Window noIcon;
    Expect(!noIcon.Create(missing, L"missing icon", 320, 240),
           "module without brand icon rejected");
    Expect(FreeLibrary(missing) != FALSE, "missing-icon fixture released");
  }

  beats::Window primary;
  beats::Window secondary;
  primary.SetDestroyCallback([](beats::Window &) {});
  secondary.SetDestroyCallback([](beats::Window &) {});
  if (Expect(primary.Create(GetModuleHandleW(nullptr), L"UX synthetic primary",
                            320, 240),
             "synthetic primary created without core or user data")) {
    primary.Show(SW_HIDE);
    CheckWindow(primary.GetHandle(), "primary class registers big icon");
  }
  if (Expect(secondary.Create(GetModuleHandleW(nullptr),
                              L"UX synthetic secondary", 320, 240),
             "synthetic secondary shares registered window class")) {
    secondary.Show(SW_HIDE);
    CheckWindow(secondary.GetHandle(), "secondary class registers big icon");
  }
  PWSTR appId = nullptr;
  const HRESULT hr = GetCurrentProcessExplicitAppUserModelID(&appId);
  Expect(SUCCEEDED(hr) && appId &&
             std::wcscmp(appId, L"AdAstra.DevAgents.DevAgents") == 0,
         "stable process AppUserModelID groups all windows");
  CoTaskMemFree(appId);
  std::printf("WINDOW BRAND: %d/%d checks passed\n", checks - failures, checks);
  return failures ? 1 : 0;
}
