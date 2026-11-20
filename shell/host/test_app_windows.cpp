// E5.21 — tests del multiventana del host.
//
// Cubre el contrato de puente `window.open` (ParseOpenWindow): vistas
// admitidas, parametros obligatorios por vista, alias tolerados y rechazo de
// cadenas que romperian la URL de navegacion. Tambien UrlEncodeComponent (la
// ruta viaja en el ?query de la webview) y el registro vacio (ByHwnd/Primary
// sobre un supervisor sin ventanas deben devolver nulo, no colgar).
//
// El ciclo de vida real (crear/poner/quitar HWND, difusion) se verifica en
// vivo con CDP en E5.22 — estos tests son la puerta de esquema.

#include "app_windows.hpp"
#include "distribution_build.h"
#define BEATS_WEBVIEW_INITIALIZATION_ONLY
#include "webview_host.cpp"
#undef BEATS_WEBVIEW_INITIALIZATION_ONLY
#include "core_dispatch.hpp"
#include "notification_policy.hpp"
#include "preview_policy.hpp"
#include "preview_selector.hpp"
#include "remote_controller.hpp"
#include "webview_policy.hpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <winioctl.h>

static int failures = 0;
static int checks = 0;

static void Expect(bool ok, const char *nombre) {
  ++checks;
  if (!ok) {
    ++failures;
    std::printf("FAIL  %s\n", nombre);
  } else {
    std::printf("ok    %s\n", nombre);
  }
}

static const std::string pickedFixture =
    "{\"kind\":\"element_picked\",\"selector\":\"#target\",\"outerHTML\":\"<"
    "button id='target'>Cambiar</button>\","
    "\"box\":{\"x\":20,\"y\":40,\"width\":120,\"height\":50},"
    "\"styles\":{\"color\":\"rgb(0, 0, 0)\",\"backgroundColor\":\"rgb(255, "
    "255, "
    "255)\",\"fontSize\":\"16px\",\"fontFamily\":\"sans-serif\",\"fontWeight\":"
    "\"400\",\"display\":\"block\",\"position\":\"static\",\"borderRadius\":"
    "\"0px\"},"
    "\"path\":\"index.html\",\"viewport\":{\"width\":800,\"height\":600,"
    "\"devicePixelRatio\":1}}";

static std::string ReplaceOne(std::string text, const std::string &old,
                              const std::string &replacement) {
  const size_t pos = text.find(old);
  if (pos == std::string::npos)
    return "";
  text.replace(pos, old.size(), replacement);
  return text;
}

// Las pruebas corren en un cwd aislado: las fuentes del host se localizan
// por BEATS_SOURCE_ROOT (lo fija build.zig); sin ella, relativo al cwd.
static std::string SourcePath(const char *relative) {
  char *root = nullptr;
  size_t len = 0;
  std::string path = relative;
  if (_dupenv_s(&root, &len, "BEATS_SOURCE_ROOT") == 0 && root != nullptr) {
    if (root[0] != '\0')
      path = std::string(root) + "/" + relative;
    free(root);
  }
  return path;
}

static std::string CompactSource(std::string text) {
  text.erase(std::remove_if(text.begin(), text.end(),
                            [](unsigned char c) { return std::isspace(c); }),
             text.end());
  return text;
}

// A directory mount point needs no SeCreateSymbolicLinkPrivilege.
static bool TestJunction(const std::wstring &link, const std::wstring &target) {
  if (!CreateDirectoryW(link.c_str(), nullptr))
    return false;
  const HANDLE h = CreateFileW(
      link.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
  if (h == INVALID_HANDLE_VALUE) {
    Expect(RemoveDirectoryW(link.c_str()) != FALSE, "junction rollback open");
    return false;
  }
  const std::wstring substitute = L"\\??\\" + target;
  const WORD subLen = static_cast<WORD>(substitute.size() * sizeof(wchar_t));
  const WORD printLen = static_cast<WORD>(target.size() * sizeof(wchar_t));
  const WORD dataLen = 8 + subLen + 2 + printLen + 2;
  std::vector<unsigned char> bytes(8 + dataLen, 0);
  const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
  const WORD printOffset = subLen + 2;
  memcpy(bytes.data(), &tag, 4);
  memcpy(bytes.data() + 4, &dataLen, 2);
  memcpy(bytes.data() + 10, &subLen, 2);
  memcpy(bytes.data() + 12, &printOffset, 2);
  memcpy(bytes.data() + 14, &printLen, 2);
  memcpy(bytes.data() + 16, substitute.data(), subLen);
  memcpy(bytes.data() + 16 + printOffset, target.data(), printLen);
  DWORD returned = 0;
  const BOOL ok = DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, bytes.data(),
                                  static_cast<DWORD>(bytes.size()), nullptr, 0,
                                  &returned, nullptr);
  CloseHandle(h);
  if (!ok)
    Expect(RemoveDirectoryW(link.c_str()) != FALSE, "junction rollback ioctl");
  return ok != FALSE;
}

static bool WritePreviewFixture(const std::wstring &path, const char *data) {
  const HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                               CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (h == INVALID_HANDLE_VALUE)
    return false;
  DWORD written = 0;
  const DWORD n = static_cast<DWORD>(strlen(data));
  const BOOL ok = WriteFile(h, data, n, &written, nullptr);
  CloseHandle(h);
  return ok && written == n;
}

struct PreviewSwapFixture {
  std::wstring directory, retired, outside;
  bool attempted = false, renamed = false, linked = false;
  static void Swap(const std::wstring &path, void *context) {
    auto &fixture = *static_cast<PreviewSwapFixture *>(context);
    if (path != fixture.directory)
      return;
    fixture.attempted = true;
    fixture.renamed = MoveFileW(path.c_str(), fixture.retired.c_str()) != FALSE;
    if (fixture.renamed)
      fixture.linked = TestJunction(path, fixture.outside);
  }
};

struct PreviewSettingsFixture {
  BOOL hostObjects = TRUE, messages = FALSE, dialogs = TRUE, menus = TRUE,
       status = TRUE, devTools = FALSE;
  int calls = 0, failAt = 0;
  HRESULT Put(BOOL &target, BOOL value) {
    if (++calls == failAt)
      return E_FAIL;
    target = value;
    return S_OK;
  }
  HRESULT put_AreHostObjectsAllowed(BOOL v) { return Put(hostObjects, v); }
  HRESULT put_IsWebMessageEnabled(BOOL v) { return Put(messages, v); }
  HRESULT put_AreDefaultScriptDialogsEnabled(BOOL v) { return Put(dialogs, v); }
  HRESULT put_AreDefaultContextMenusEnabled(BOOL v) { return Put(menus, v); }
  HRESULT put_IsStatusBarEnabled(BOOL v) { return Put(status, v); }
  HRESULT put_AreDevToolsEnabled(BOOL v) { return Put(devTools, v); }
};

// BAJO-4 (el modelo r1): la WebView principal deniega permisos y descargas,
// apaga los diálogos de script y no ignora ningún HRESULT de sus ajustes.
struct MainSettingsFixture {
  BOOL devTools = TRUE, hostObjects = TRUE, messages = FALSE, dialogs = TRUE,
       errorPage = TRUE, menus = TRUE;
  int calls = 0, failAt = 0;
  HRESULT Put(BOOL &target, BOOL value) {
    if (++calls == failAt)
      return E_FAIL;
    target = value;
    return S_OK;
  }
  HRESULT put_AreDevToolsEnabled(BOOL v) { return Put(devTools, v); }
  HRESULT put_AreHostObjectsAllowed(BOOL v) { return Put(hostObjects, v); }
  HRESULT put_IsWebMessageEnabled(BOOL v) { return Put(messages, v); }
  HRESULT put_AreDefaultScriptDialogsEnabled(BOOL v) { return Put(dialogs, v); }
  HRESULT put_IsBuiltInErrorPageEnabled(BOOL v) { return Put(errorPage, v); }
  HRESULT put_AreDefaultContextMenusEnabled(BOOL v) { return Put(menus, v); }
};

struct PermissionArgsFixture {
  COREWEBVIEW2_PERMISSION_STATE state = COREWEBVIEW2_PERMISSION_STATE_ALLOW;
  int calls = 0;
  HRESULT result = S_OK;
  HRESULT put_State(COREWEBVIEW2_PERMISSION_STATE value) {
    ++calls;
    if (FAILED(result))
      return result;
    state = value;
    return S_OK;
  }
};

struct DownloadArgsFixture {
  BOOL cancelled = FALSE, handled = FALSE;
  int cancelCalls = 0, handledCalls = 0;
  HRESULT cancelResult = S_OK, handledResult = S_OK;
  HRESULT put_Cancel(BOOL value) {
    ++cancelCalls;
    if (FAILED(cancelResult))
      return cancelResult;
    cancelled = value;
    return S_OK;
  }
  HRESULT put_Handled(BOOL value) {
    ++handledCalls;
    if (FAILED(handledResult))
      return handledResult;
    handled = value;
    return S_OK;
  }
};

struct LifecycleHandlerFixture {
  int &alive;
  int refs = 1;
  explicit LifecycleHandlerFixture(int &count) : alive(count) { ++alive; }
  void AddRef() { ++refs; }
  void Release() {
    if (--refs == 0) {
      --alive;
      delete this;
    }
  }
};

// Structural COM doubles, matching the settings fixtures above. Successful
// add_* retains its handler, and remove_* releases exactly the supplied token.
struct LifecycleFixture {
  int calls = 0, failAt = 0, refs = 1, aliveHandlers = 0;
  bool visible = false, navigated = false;
  HRESULT removeResult = S_OK;
  LifecycleHandlerFixture *handlers[3] = {};
  std::vector<int> removed;
  HRESULT Next() { return ++calls == failAt ? E_ACCESSDENIED : S_OK; }
  void AddRef() { ++refs; }
  void Release() { --refs; }
  HRESULT put_DefaultBackgroundColor(COREWEBVIEW2_COLOR color) {
    if (color.A != 255 || color.R != 10 || color.G != 10 || color.B != 10)
      return E_INVALIDARG;
    return Next();
  }
  HRESULT put_IsVisible(BOOL value) {
    const HRESULT hr = Next();
    if (SUCCEEDED(hr))
      visible = value != FALSE;
    return hr;
  }
  HRESULT Add(int index, LifecycleHandlerFixture *handler,
              EventRegistrationToken *token) {
    const HRESULT hr = Next();
    if (FAILED(hr))
      return hr;
    token->value = index; // zero is a valid token, not an unregistered marker
    handler->AddRef();
    handlers[index] = handler;
    return S_OK;
  }
  HRESULT Remove(EventRegistrationToken token) {
    const int index = static_cast<int>(token.value);
    if (index < 0 || index > 2 || !handlers[index])
      return E_INVALIDARG;
    removed.push_back(index);
    handlers[index]->Release();
    handlers[index] = nullptr;
    return removeResult;
  }
  HRESULT add_NavigationCompleted(LifecycleHandlerFixture *handler,
                                  EventRegistrationToken *token) {
    return Add(0, handler, token);
  }
  HRESULT add_ProcessFailed(LifecycleHandlerFixture *handler,
                            EventRegistrationToken *token) {
    return Add(1, handler, token);
  }
  HRESULT add_DOMContentLoaded(LifecycleHandlerFixture *handler,
                               EventRegistrationToken *token) {
    return Add(2, handler, token);
  }
  HRESULT remove_NavigationCompleted(EventRegistrationToken t) {
    return Remove(t);
  }
  HRESULT remove_ProcessFailed(EventRegistrationToken t) { return Remove(t); }
  HRESULT remove_DOMContentLoaded(EventRegistrationToken t) {
    return Remove(t);
  }
  HRESULT Navigate(const wchar_t *url) {
    if (std::wstring(url) != L"https://devagents.local/index.html?ventana=2")
      return E_INVALIDARG;
    const HRESULT hr = Next();
    navigated = SUCCEEDED(hr);
    return hr;
  }
};

static void MainViewLifecycleTests() {
  using namespace beats::webview_init;
  for (int failAt = 0; failAt <= 6; ++failAt) {
    LifecycleFixture fixture;
    fixture.failAt = failAt;
    Subscriptions subscriptions;
    int aborts = 0, reports = 0;
    HRESULT visibleError = S_OK;
    bool initialized = false;
    const HRESULT hr = Run(
        [&]() -> HRESULT {
          const HRESULT appearance = ConfigureController(&fixture, &fixture);
          if (FAILED(appearance))
            return appearance;
          const HRESULT started = Start(
              &fixture, &fixture,
              new LifecycleHandlerFixture(fixture.aliveHandlers),
              new LifecycleHandlerFixture(fixture.aliveHandlers),
              new LifecycleHandlerFixture(fixture.aliveHandlers),
              L"https://devagents.local/index.html?ventana=2", subscriptions);
          initialized = SUCCEEDED(started);
          return started;
        },
        [&]() {
          ++aborts;
          subscriptions.Clear();
          initialized = false;
          fixture.visible = false;
        },
        [&](HRESULT error) {
          ++reports;
          visibleError = error;
        });
    if (failAt) {
      Expect(hr == E_ACCESSDENIED && !initialized && aborts == 1 &&
                 reports == 1 && visibleError == E_ACCESSDENIED,
             "CK-SEG-011 H9 HRESULT fallido en ajuste/registro/Navigate aborta "
             "con error visible");
      Expect(fixture.calls == failAt && !fixture.navigated,
             "CK-SEG-011 H9 no continua ni navega despues del HRESULT fallido");
      Expect(fixture.refs == 1 && fixture.aliveHandlers == 0 &&
                 !fixture.visible,
             "CK-SEG-011 H9 fallo retira registros parciales y libera "
             "referencias COM");
    } else {
      Expect(hr == S_OK && initialized && reports == 0 && aborts == 0 &&
                 fixture.calls == 6 && fixture.navigated && fixture.visible &&
                 fixture.refs == 4 && fixture.aliveHandlers == 3,
             "CK-SEG-011 H9 arranque exitoso configura registra y navega");
    }
    const size_t removedBefore = fixture.removed.size();
    Expect(SUCCEEDED(subscriptions.Clear()) && fixture.refs == 1 &&
               fixture.aliveHandlers == 0,
           "CK-SEG-011 H9 cierre retira handlers incluido token cero y libera "
           "COM");
    const size_t removedAfter = fixture.removed.size();
    Expect(SUCCEEDED(subscriptions.Clear()) &&
               fixture.removed.size() == removedAfter &&
               (failAt || (removedBefore == 0 &&
                           fixture.removed == std::vector<int>{2, 1, 0})),
           "CK-SEG-011 H9 retirada inversa una sola vez y cierre idempotente");
  }
  {
    LifecycleFixture fixture;
    Subscriptions subscriptions;
    for (int index = 0; index < 2; ++index)
      Expect(SUCCEEDED(subscriptions.AddHandler(
                 &fixture,
                 index == 0 ? &LifecycleFixture::add_NavigationCompleted
                            : &LifecycleFixture::add_ProcessFailed,
                 index == 0 ? &LifecycleFixture::remove_NavigationCompleted
                            : &LifecycleFixture::remove_ProcessFailed,
                 new LifecycleHandlerFixture(fixture.aliveHandlers))),
             "CK-SEG-011 H9 prepara cierre con varios registros");
    fixture.removeResult = E_FAIL;
    Expect(subscriptions.Clear() == E_FAIL && fixture.removed.size() == 2 &&
               fixture.refs == 1 && fixture.aliveHandlers == 0,
           "CK-SEG-011 H9 fallo de retirada se propaga y no omite los demas "
           "handlers");
  }
}

static void MainViewPolicyTests() {
  using namespace beats::webview_policy;
  {
    MainSettingsFixture settings;
    Expect(SUCCEEDED(ApplyMainViewSettings(&settings, false)) &&
               !settings.devTools && !settings.hostObjects &&
               settings.messages && !settings.dialogs && !settings.errorPage &&
               !settings.menus && settings.calls == 6,
           "BAJO-4 ajustes de la vista principal: sin diálogos de script, "
           "menús ni objetos del host");
    Expect(SUCCEEDED(ApplyMainViewSettings(&settings, true)) &&
               settings.devTools && !settings.dialogs,
           "BAJO-4 DevTools sigue siendo opción del host y los diálogos "
           "permanecen apagados");
    Expect(FAILED(ApplyMainViewSettings<MainSettingsFixture>(nullptr, false)),
           "BAJO-4 ajustes nulos fallan");
    for (int i = 1; i <= 6; ++i) {
      MainSettingsFixture failing;
      failing.failAt = i;
      Expect(FAILED(ApplyMainViewSettings(&failing, false)) &&
                 failing.calls == i,
             "BAJO-4 un HRESULT fallido en cada ajuste aborta la "
             "configuración (no se ignora)");
    }
  }
  {
    PermissionArgsFixture args;
    Expect(SUCCEEDED(DenyPermission(&args)) &&
               args.state == COREWEBVIEW2_PERMISSION_STATE_DENY &&
               args.calls == 1,
           "BAJO-4 PermissionRequested deniega");
    PermissionArgsFixture failing;
    failing.result = E_FAIL;
    Expect(FAILED(DenyPermission(&failing)) &&
               failing.state != COREWEBVIEW2_PERMISSION_STATE_DENY,
           "BAJO-4 un put_State fallido se propaga (no se ignora)");
    Expect(FAILED(DenyPermission<PermissionArgsFixture>(nullptr)),
           "BAJO-4 permiso con argumentos nulos falla");
  }
  {
    DownloadArgsFixture args;
    Expect(SUCCEEDED(CancelDownload(&args)) && args.cancelled && args.handled &&
               args.cancelCalls == 1 && args.handledCalls == 1,
           "BAJO-4 DownloadStarting cancela y marca la descarga como tratada");
    DownloadArgsFixture cancelFails;
    cancelFails.cancelResult = E_FAIL;
    Expect(FAILED(CancelDownload(&cancelFails)) && !cancelFails.cancelled &&
               cancelFails.handledCalls == 0,
           "BAJO-4 put_Cancel fallido se propaga sin dar la descarga por "
           "tratada");
    DownloadArgsFixture handledFails;
    handledFails.handledResult = E_FAIL;
    Expect(FAILED(CancelDownload(&handledFails)) && handledFails.cancelled,
           "BAJO-4 put_Handled fallido se propaga (la descarga queda "
           "cancelada)");
    Expect(FAILED(CancelDownload<DownloadArgsFixture>(nullptr)),
           "BAJO-4 descarga con argumentos nulos falla");
  }
  {
    // P2-3 (restaurado del bloque que la ronda 1 borró y
    // adaptado al reparto webview_init/webview_policy): la inicialización
    // real del producto debe seguir llamando a Run, ConfigureController y
    // Start, y registrando permisos y descargas con las políticas, sin
    // put_* de la vista principal con HRESULT ignorado.
    std::ifstream source(SourcePath("shell/host/webview_host.cpp"));
    std::ostringstream contents;
    contents << source.rdbuf();
    const std::string compact = CompactSource(contents.str());
    Expect(source.is_open() &&
               compact.find(CompactSource("webview_init::Run(")) !=
                   std::string::npos &&
               compact.find(CompactSource(
                   "webview_init::ConfigureController(controller, "
                   "controller2)")) != std::string::npos &&
               compact.find(CompactSource("webview_init::Start(")) !=
                   std::string::npos,
           "CK-SEG-011 P2-3 la inicializacion de producto llama a Run "
           "ConfigureController y Start");
    Expect(compact.find(CompactSource(
               "webview_policy::ApplyMainViewSettings(")) != std::string::npos,
           "CK-SEG-011 P2-3 la WebView principal aplica ApplyMainViewSettings");
    Expect(compact.find(CompactSource(
               "webView, &ICoreWebView2::add_PermissionRequested")) !=
               std::string::npos,
           "CK-SEG-011 P2-3 la WebView principal registra PermissionRequested");
    Expect(compact.find(CompactSource(
               "downloadView, &ICoreWebView2_4::add_DownloadStarting")) !=
               std::string::npos,
           "CK-SEG-011 P2-3 la WebView principal registra DownloadStarting");
    Expect(
        compact.find(CompactSource("webview_policy::DenyPermission(args)")) !=
                std::string::npos &&
            compact.find(CompactSource(
                "webview_policy::CancelDownload(args)")) != std::string::npos,
        "CK-SEG-011 P2-3 los manejadores usan DenyPermission y "
        "CancelDownload");
    Expect(compact.find(CompactSource(
               "settings->put_IsBuiltInErrorPageEnabled(FALSE);")) ==
                   std::string::npos &&
               compact.find(CompactSource(
                   "settings->put_AreDefaultContextMenusEnabled(FALSE);")) ==
                   std::string::npos,
           "CK-SEG-011 P2-3 no quedan put_* de la vista principal con "
           "HRESULT ignorado");
  }
}

static void PreviewTests() {
  using namespace beats::preview;
  {
    Expect(FinalPath(INVALID_HANDLE_VALUE).empty() &&
               FinalPath(nullptr).empty(),
           "E5.25 final path invalid handle fails closed");
    Expect(CanonicalRoot(L"").empty() &&
               CanonicalRoot(std::wstring(4097, L'x')).empty(),
           "E5.25 canonical root invalid input fails closed");
    Expect(Within(L"\\\\?\\C:\\root", L"\\\\?\\c:\\ROOT\\index.html") &&
               !Within(L"\\\\?\\C:\\root",
                       L"\\\\?\\C:\\root-foreign\\index.html") &&
               !Within(L"\\\\?\\C:\\root", L"\\\\?\\C:\\root") &&
               !Within(L"", L"\\\\?\\C:\\index.html"),
           "E5.25 final handle containment has boundary and case checks");
    for (const auto &entry :
         std::vector<std::pair<const wchar_t *, const wchar_t *>>{
             {L"a.HTML", L"text/html; charset=utf-8"},
             {L"a.htm", L"text/html; charset=utf-8"},
             {L"a.css", L"text/css; charset=utf-8"},
             {L"a.js", L"text/javascript; charset=utf-8"},
             {L"a.mjs", L"text/javascript; charset=utf-8"},
             {L"a.json", L"application/json"},
             {L"a.map", L"application/json"},
             {L"a.png", L"image/png"},
             {L"a.jpg", L"image/jpeg"},
             {L"a.jpeg", L"image/jpeg"},
             {L"a.webp", L"image/webp"},
             {L"a.gif", L"image/gif"},
             {L"a.svg", L"image/svg+xml"},
             {L"a.ico", L"image/x-icon"},
             {L"a.woff", L"font/woff"},
             {L"a.woff2", L"font/woff2"},
             {L"a.ttf", L"font/ttf"},
             {L"a.otf", L"font/otf"},
             {L"a.wasm", L"application/wasm"},
             {L"a.txt", L"text/plain; charset=utf-8"},
             {L"a.mp4", L"video/mp4"},
             {L"a.webm", L"video/webm"},
             {L"a.mp3", L"audio/mpeg"},
             {L"a.wav", L"audio/wav"},
             {L"a.ogg", L"application/ogg"},
             {L"unknown", L"application/octet-stream"}})
      Expect(wcscmp(ResourceType(L"https://preview.local/" +
                                 std::wstring(entry.first)),
                    entry.second) == 0,
             "E5.25 response content type follows resource extension");
    Expect(wcscmp(ResourceType(L"https://foreign.local/a.html"),
                  L"application/octet-stream") == 0,
           "E5.25 content type invalid URL fails closed");
  }
  {
    PreviewSettingsFixture settings;
    Expect(SUCCEEDED(ApplySettings(&settings, true)) && !settings.hostObjects &&
               settings.messages && !settings.dialogs && !settings.menus &&
               !settings.status && settings.devTools,
           "E5.25 COM settings disable host objects on actual product path");
    Expect(SUCCEEDED(ApplySettings(&settings, false)) && !settings.devTools,
           "E5.25 devtools sigue opción host");
    Expect(FAILED(ApplySettings<PreviewSettingsFixture>(nullptr, false)),
           "E5.25 settings nulos fallan");
    for (int i = 1; i <= 6; ++i) {
      PreviewSettingsFixture failing;
      failing.failAt = i;
      Expect(FAILED(ApplySettings(&failing, false)) && failing.calls == i,
             "E5.25 fallo COM en cada ajuste aborta configuración");
    }
    std::ifstream source(SourcePath("shell/host/app_windows.cpp"));
    std::ostringstream contents;
    contents << source.rdbuf();
    Expect(source.is_open() &&
               CompactSource(contents.str())
                       .find(CompactSource(
                           "if (aw->vista != \"preview\") "
                           "aw->webview.PostMessageJson(jsonMessage);")) !=
                   std::string::npos,
           "E5.25 difusión excluye previews en fuente de producto");
    Expect(source.is_open() &&
               CompactSource(contents.str())
                       .find(CompactSource(
                           "if (aw->vista != \"preview\" && aw->vista != "
                           "\"browser\") aw->bridge = "
                           "std::make_shared<Bridge>();")) != std::string::npos,
           "E5.25 registro no crea Bridge para preview ni navegador");
    Expect(beats::WebViewHost::MessageWithinBound(0) &&
               beats::WebViewHost::MessageWithinBound(
                   beats::WebViewHost::BridgeMessageLimit) &&
               !beats::WebViewHost::MessageWithinBound(
                   beats::WebViewHost::BridgeMessageLimit + 1),
           "E5.23/E5.25 transporte 28MiB exigible antes de cola");
    std::ifstream mainSource(SourcePath("shell/host/main.cpp"));
    std::ostringstream mainContents;
    mainContents << mainSource.rdbuf();
    const size_t guard =
        CompactSource(mainContents.str())
            .find(CompactSource("!beats::WebViewHost::MessageWithinBound("
                                "static_cast<size_t>(size_needed))"));
    const size_t queue =
        CompactSource(mainContents.str())
            .find(CompactSource("requestQueue.push_back({rawJson, aw.hwnd, "
                                "nullptr, aw.bridge})"));
    Expect(mainSource.is_open() && guard != std::string::npos &&
               queue != std::string::npos && guard < queue,
           "E5.23/E5.25 cota bytes antes de encolar petición motor");
  }
  {
    const auto r = beats::ParseOpenWindow(
        "{\"vista\":\"preview\",\"order_id\":23,\"path\":\"page/index.html\"}");
    Expect(r.valid && r.vista == "preview" && r.orderId == 23,
           "E5.25 preview relativa con orden");
    Expect(beats::ParseOpenWindow("{\"vista\":\"preview\",\"order_id\":23}")
                   .path == "index.html",
           "E5.25 preview usa index.html explícito");
    for (const char *raw :
         {"{\"vista\":\"preview\",\"order_id\":\"23\"}",
          "{\"vista\":\"preview\",\"order_id\":1.5}",
          "{\"vista\":\"preview\",\"order_id\":0}",
          "{\"vista\":\"preview\",\"order_id\":23,\"path\":\"../x.html\"}",
          "{\"vista\":\"preview\",\"order_id\":23,\"path\":\"C:/x.html\"}",
          "{\"vista\":\"preview\",\"order_id\":23,\"path\":\"index.js\"}",
          "{\"vista\":\"preview\",\"order_id\":23,\"unknown\":2}",
          "{\"vista\":\"preview\",\"order_id\":23,\"order_id\":24}"})
      Expect(!beats::ParseOpenWindow(raw).valid,
             "E5.25 preview rechaza contrato/ruta inválido");
  }
  {
    Value v;
    std::string reason;
    Expect(Picked(pickedFixture, v, reason),
           "E5.25 esquema element_picked válido");
    Expect(Provenance(L"https://preview.local/index.html",
                      L"https://preview.local/index.html", v),
           "E5.25 origen superior coincide ruta");
    Expect(!Provenance(L"https://devagents.local/index.html",
                       L"https://devagents.local/index.html", v),
           "E5.25 origen cabina rechazado");
    Expect(!Provenance(L"https://preview.local/index.html",
                       L"https://preview.local/other.html", v),
           "E5.25 origen antiguo rechazado");
    Value empty;
    Expect(!Provenance(L"https://preview.local/index.html",
                       L"https://preview.local/index.html", empty),
           "E5.25 origen sin ruta rechazado");
  }
  const std::vector<std::string> invalid = {
      "{}",
      "{",
      "[]",
      pickedFixture + " garbage",
      ReplaceOne(pickedFixture, "element_picked", "core.order.submit"),
      ReplaceOne(pickedFixture, "\"selector\":\"#target\"",
                 "\"selector\":\"#target\",\"selector\":\"#other\""),
      ReplaceOne(pickedFixture, "\"x\":20", "\"x\":-1"),
      ReplaceOne(pickedFixture, "\"x\":20", "\"x\":790"),
      ReplaceOne(pickedFixture, "\"width\":120", "\"width\":0"),
      ReplaceOne(pickedFixture, "\"width\":800", "\"width\":8193"),
      ReplaceOne(pickedFixture, "\"height\":600", "\"height\":0"),
      ReplaceOne(pickedFixture, "\"devicePixelRatio\":1",
                 "\"devicePixelRatio\":9"),
      ReplaceOne(pickedFixture, "\"x\":20", "\"x\":1e999"),
      ReplaceOne(pickedFixture, "\"x\":20", "\"x\":NaN"),
      ReplaceOne(pickedFixture, "\"x\":20", "\"x\":020"),
      ReplaceOne(pickedFixture, "\"x\":20", "\"x\":true"),
      ReplaceOne(pickedFixture, "\"x\":20", "\"x\":{}"),
      ReplaceOne(pickedFixture, "\"path\":\"index.html\"",
                 "\"path\":\"../owner.txt\""),
      ReplaceOne(pickedFixture, "\"path\":\"index.html\"",
                 "\"path\":\"/index.html\""),
      ReplaceOne(pickedFixture, "\"path\":\"index.html\"",
                 "\"path\":\"index.html:stream\""),
      ReplaceOne(pickedFixture, "\"selector\":\"#target\"",
                 "\"selector\":\"\\u0000\""),
      ReplaceOne(pickedFixture, "\"selector\":\"#target\"",
                 "\"selector\":\"\\ud800\""),
      ReplaceOne(pickedFixture, "\"selector\":\"#target\"",
                 "\"selector\":\"\\x00\""),
      ReplaceOne(pickedFixture, "\"position\":\"static\"",
                 "\"position\":\"static\",\"secret\":\"value\""),
      ReplaceOne(pickedFixture, "\"position\":\"static\"", "\"position\":0"),
      ReplaceOne(pickedFixture, "\"selector\":\"#target\"",
                 "\"selector\":\"" + std::string(1025, 'x') + "\""),
      ReplaceOne(pickedFixture, "<button id='target'>Cambiar</button>",
                 std::string(8193, 'x')),
      ReplaceOne(pickedFixture, "\"position\":\"static\"",
                 "\"position\":\"" + std::string(257, 'x') + "\""),
      std::string(MessageLimit + 1, ' '),
      ReplaceOne(pickedFixture, "#target", std::string("\xff\xfe", 2))};
  for (const auto &raw : invalid) {
    Value v;
    std::string reason;
    Expect(!Picked(raw, v, reason) && !reason.empty(),
           "E5.25 mensaje no confiable rechazado con motivo");
  }
  {
    Value v;
    std::string reason;
    Expect(Picked(ReplaceOne(pickedFixture, "#target",
                             "#bot\\u00f3n\\ud83d\\ude00"),
                  v, reason),
           "E5.25 Unicode válido preservado");
    for (const auto &raw :
         {std::string("{\"n\":1.}"), std::string("{\"n\":1e}"),
          std::string("{\"n\":-}"),
          std::string("{\"a\":{\"b\":{\"c\":{\"d\":{\"e\":1}}}}}"),
          std::string("{\"n\":null}")}) {
      Value parsed;
      Expect(!Parser(raw).Parse(parsed),
             "E5.25 parser acotado rechaza JSON malformado/tipo/profundidad");
    }
  }
  {
    std::string path;
    Expect(UrlPath(L"https://preview.local/a%20b/index.html?x=1", path) &&
               path == "a b/index.html",
           "E5.25 URL UTF8 relativa decodificada");
    for (const wchar_t *url :
         {L"https://preview.local.evil/index.html",
          L"https://preview.local@evil/index.html", L"file:///index.html",
          L"http://preview.local/index.html",
          L"https://preview.local/%2e%2e/owner.txt",
          L"https://preview.local/a%3ab.html",
          L"https://preview.local/a%00b.html", L"https://preview.local/a%2",
          L"https://preview.local/a%zz"}) {
      std::string bad;
      Expect(!UrlPath(url, bad), "E5.25 esquema/escape/origen URL rechazado");
    }
    Expect(!Relative("a\\b.html") && !Relative("a/../b.html") &&
               !Relative("a//b.html") && !Relative("a./b.html"),
           "E5.25 traversal y normalización Windows rechazados");
    Expect(HtmlPath("a/Index.HTML") && !HtmlPath("index.css"),
           "E5.25 navegación solo HTML");
    const unsigned char bytes[] = {'f', 'o', 'o'};
    Expect(Base64(bytes, 3) == "Zm9v" && Base64(bytes, 1) == "Zg==" &&
               Base64(bytes, 2) == "Zm8=",
           "E5.25 base64 captura exacto");
    Expect(Base64(nullptr, 3).empty() && Base64(bytes, 0).empty() &&
               Base64(bytes, CaptureLimit + 1).empty(),
           "E5.25 captura vacía/excesiva rechazada");
    Expect(!Wide(std::string(100000, 'a')).empty(),
           "E5.25 push captura supera cota del mensaje entrante sin truncarse");
    Expect(Wide(std::string(CaptureLimit * 2 + MessageLimit + 1, 'a')).empty(),
           "E5.25 conversión saliente acotada");
    Expect(Narrow(Wide("botón")) == "botón" && !Utf8(std::string("\xff", 1)),
           "E5.25 UTF8 válido e inválido");
    Expect(
        std::wstring(beats::PreviewSelectorScript()).find(L"event.isTrusted") !=
                std::wstring::npos &&
            std::wstring(beats::PreviewSelectorScript())
                    .find(L"window!==window.top") != std::wstring::npos,
        "E5.25 selector exige documento superior y gesto real");
  }
  {
    wchar_t tmp[MAX_PATH], folder[MAX_PATH];
    const DWORD n = GetTempPathW(MAX_PATH, tmp);
    const UINT created =
        n > 0 && n < MAX_PATH ? GetTempFileNameW(tmp, L"e25", 0, folder) : 0;
    Expect(created != 0, "E5.25 fixture temporal creado");
    if (created) {
      const bool removed = DeleteFileW(folder) != FALSE;
      const bool made = removed && CreateDirectoryW(folder, nullptr) != FALSE;
      Expect(made, "E5.25 carpeta fixture creada");
      if (made) {
        const std::wstring file = std::wstring(folder) + L"\\index.html";
        const HANDLE handle =
            CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                        FILE_ATTRIBUTE_NORMAL, nullptr);
        Expect(handle != INVALID_HANDLE_VALUE, "E5.25 archivo fixture creado");
        if (handle != INVALID_HANDLE_VALUE)
          CloseHandle(handle);
        std::string reason;
        Expect(SafeTree(folder, reason), "E5.25 preflight árbol regular");
        Expect(Resource(folder, L"https://preview.local/index.html"),
               "E5.25 recurso local regular permitido");
        Expect(!Resource(folder, L"https://preview.local/missing.html"),
               "E5.25 recurso ausente rechazado");
        Expect(!Resource(folder, L"https://devagents.local/index.html"),
               "E5.25 recurso cabina rechazado");
        std::vector<unsigned char> resourceBytes{1};
        Expect(ReadResource(folder, L"https://preview.local/index.html",
                            resourceBytes) &&
                   resourceBytes.empty(),
               "E5.25 checked empty file read from open handle");
        resourceBytes.push_back(1);
        Expect(!ReadResource(folder, L"https://preview.local/missing.html",
                             resourceBytes) &&
                   resourceBytes.empty(),
               "E5.25 failed resource cannot return stale bytes");
        Expect(CanonicalRoot(file).empty() && !CanonicalRoot(folder).empty(),
               "E5.25 canonical root requires real directory");
        const std::wstring big = std::wstring(folder) + L"\\oversized.bin";
        const HANDLE bigHandle =
            CreateFileW(big.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                        FILE_ATTRIBUTE_NORMAL, nullptr);
        Expect(bigHandle != INVALID_HANDLE_VALUE,
               "E5.25 resource limit fixture opened");
        if (bigHandle != INVALID_HANDLE_VALUE) {
          LARGE_INTEGER beyond{};
          beyond.QuadPart = ResourceLimit + 1;
          Expect(SetFilePointerEx(bigHandle, beyond, nullptr, FILE_BEGIN) &&
                     SetEndOfFile(bigHandle),
                 "E5.25 resource limit fixture extended");
          CloseHandle(bigHandle);
          Expect(!ReadResource(folder, L"https://preview.local/oversized.bin",
                               resourceBytes) &&
                     resourceBytes.empty(),
                 "E5.25 resource byte bound rejects oversized file");
          Expect(DeleteFileW(big.c_str()) != FALSE,
                 "E5.25 resource limit fixture removed");
        }
        beats::WebViewHost host;
        Expect(host.ConfigurePreview(folder, "index.html", 23, 2,
                                     [](const std::wstring &) {}),
               "E5.25 host aislado configurado");
        Expect(host.IsPreview() && !host.GetMessageCallback() &&
                   !host.PostMessageJson(L"{}"),
               "E5.25 host preview carece callback puente y rechaza difusión");
        Expect(FAILED(host.InitializePreview(nullptr, false)),
               "E5.25 inicialización sin WebView falla honesta");
        Expect(!host.ConfigurePreview(folder, "../index.html", 23, 2,
                                      [](const std::wstring &) {}),
               "E5.25 configuración con escape rechazada");
        const std::wstring link = std::wstring(folder) + L"\\link";
        const bool linked = TestJunction(link, folder);
        Expect(linked, "E5.25 junction real sin privilegio creada");
        if (linked) {
          reason.clear();
          Expect(!SafeTree(folder, reason) && !reason.empty(),
                 "E5.25 preflight detecta enlace real");
          Expect(!Resource(folder, L"https://preview.local/link/index.html"),
                 "E5.25 recurso por enlace rechazado");
          Expect(RemoveDirectoryW(link.c_str()) != FALSE,
                 "E5.25 enlace fixture retirado");
        }
        PreviewSwapFixture swap{std::wstring(folder) + L"\\swap",
                                std::wstring(folder) + L"\\retired",
                                std::wstring(folder) + L"-outside"};
        const bool dirs = CreateDirectoryW(swap.directory.c_str(), nullptr) &&
                          CreateDirectoryW(swap.outside.c_str(), nullptr);
        Expect(dirs, "E5.25 TOCTOU carpetas propias creadas");
        if (dirs) {
          const bool files =
              WritePreviewFixture(swap.directory + L"\\index.html", "INSIDE") &&
              WritePreviewFixture(swap.outside + L"\\index.html", "OUTSIDE");
          Expect(files, "E5.25 TOCTOU contenido dentro y fuera distinto");
          if (files) {
            const bool allowed =
                Resource(folder, L"https://preview.local/swap/index.html",
                         PreviewSwapFixture::Swap, &swap);
            std::printf("TOCTOU_ALLOWED=%d ATTEMPTED=%d RENAMED=%d LINKED=%d\n",
                        allowed, swap.attempted, swap.renamed, swap.linked);
            Expect(allowed && swap.attempted && !swap.renamed && !swap.linked,
                   "E5.25 TOCTOU retarget concurrente queda bloqueado");
            swap.attempted = false;
            Expect(
                ReadResource(folder, L"https://preview.local/swap/index.html",
                             resourceBytes, PreviewSwapFixture::Swap, &swap) &&
                    swap.attempted && !swap.renamed &&
                    std::string(resourceBytes.begin(), resourceBytes.end()) ==
                        "INSIDE",
                "E5.25 TOCTOU bytes come from pinned checked handle");
          }
          if (swap.linked)
            Expect(RemoveDirectoryW(swap.directory.c_str()) != FALSE,
                   "E5.25 TOCTOU junction propio retirado");
          if (swap.renamed)
            Expect(MoveFileW(swap.retired.c_str(), swap.directory.c_str()) !=
                       FALSE,
                   "E5.25 TOCTOU carpeta original restaurada");
          Expect(DeleteFileW((swap.directory + L"\\index.html").c_str()) &&
                     DeleteFileW((swap.outside + L"\\index.html").c_str()) &&
                     RemoveDirectoryW(swap.directory.c_str()) &&
                     RemoveDirectoryW(swap.outside.c_str()),
                 "E5.25 TOCTOU fixtures retirados");
        }
        Expect(DeleteFileW(file.c_str()) != FALSE &&
                   RemoveDirectoryW(folder) != FALSE,
               "E5.25 fixture propio retirado");
      }
    }
    std::string reason;
    Expect(!SafeTree(L"", reason) && !reason.empty(),
           "E5.25 raíz inválida rechazada con motivo");
  }
}

int main() {
  Expect(DA_DISTRIBUTION_RELEASE_SAFE && DA_DISTRIBUTION_NDEBUG &&
             DA_DISTRIBUTION_RUNTIME_BINARIES_WIRED &&
             DA_DISTRIBUTION_SHELL_STEP_WIRED && DA_DEFAULT_INSTALL_DEV_HOST,
         "CK-SEG-011 H8 artefacto distribuible runtime-binaries exige "
         "ReleaseSafe y NDEBUG");
  {
    int invoked = 0;
    auto operation = [&] {
      ++invoked;
      return beats::CoreResult{0, "{}", ""};
    };
    auto immediate = [](std::function<void()> task) {
      task();
      return true;
    };
    auto result = beats::DispatchCoreCall(immediate, operation, nullptr);
    Expect(result.ok() && result.json == "{}" && invoked == 1,
           "E5.30 dispatched core result returned");
    Expect(!beats::DispatchCoreCall(
                immediate, [] { return beats::CoreResult{-3, "", "fixture"}; },
                nullptr)
                .ok(),
           "E5.30 dispatched core error retained");
    std::thread worker;
    result = beats::DispatchCoreCall(
        [&](std::function<void()> task) {
          worker = std::thread(std::move(task));
          return true;
        },
        operation, nullptr);
    worker.join();
    Expect(result.ok() && invoked == 2,
           "E5.30 caller waits for existing worker result");
    std::function<void()> queued;
    auto defer = [&](std::function<void()> task) {
      queued = std::move(task);
      return true;
    };
    result = beats::DispatchCoreCall(defer, operation, nullptr, 1);
    Expect(!result.ok() && result.error.find("plazo") != std::string::npos,
           "E5.30 core queue deadline returned");
    queued();
    Expect(invoked == 2, "E5.30 expired core task never accesses handle");
    HANDLE stop = CreateEventW(nullptr, TRUE, TRUE, nullptr);
    Expect(stop != nullptr, "E5.30 dispatch cancellation event created");
    result = beats::DispatchCoreCall(defer, operation, stop);
    Expect(!result.ok() && invoked == 2,
           "E5.30 stopped core task not enqueued");
    ResetEvent(stop);
    result = beats::DispatchCoreCall(
        [&](std::function<void()> task) {
          queued = std::move(task);
          SetEvent(stop);
          return true;
        },
        operation, stop);
    queued();
    Expect(!result.ok() && invoked == 2,
           "E5.30 stop releases caller and cancels retained queue task");
    CloseHandle(stop);
    result = beats::DispatchCoreCall(
        [](std::function<void()>) { return false; }, operation, nullptr);
    Expect(!result.ok() && invoked == 2, "E5.30 closed core queue rejected");
  }
  {
    beats::preview::Value v;
    const std::string batch = "{\"cursor\":12,\"items\":[{\"id\":12,\"order_"
                              "id\":42,\"state\":\"done\"}]}";
    Expect(beats::preview::Parser(batch, true).Parse(v) &&
               v.object.at("items").array.size() == 1,
           "E5.29 native transition array parsed with opt-in");
    beats::preview::Value previewValue;
    Expect(!beats::preview::Parser(batch).Parse(previewValue),
           "E5.25 preview parser retains no-array default");
    for (const std::string bad : {"[1,]", "[", "[1]{}", "[[[[[[1]]]]]]"}) {
      beats::preview::Value invalid;
      Expect(!beats::preview::Parser(bad, true).Parse(invalid),
             "E5.29 malformed or excessive-depth notification array rejected");
    }
    std::string tooMany = "[";
    for (int i = 0; i < 129; ++i)
      tooMany += (i ? ",1" : "1");
    tooMany += ']';
    beats::preview::Value oversized;
    Expect(!beats::preview::Parser(tooMany, true).Parse(oversized),
           "E5.29 notification batch capped at 128");
  }
  {
    beats::CoreClient isolated(beats::CoreClient::InitMode::isolated_empty);
    Expect(!isolated.EngineReady() && isolated.RuntimeDbPath().empty(),
           "E5.30 isolated CoreClient does not resolve owner data");
    beats::RemoteController controller(isolated);
    Expect(!controller.Start("{\"port\":-1}").ok(),
           "E5.30 controller reports invalid launch options");
    Expect(!controller.Start("{}").ok(),
           "E5.30 controller reports missing core without spawning");
    const auto state = controller.Status();
    Expect(state.ok() &&
               state.json.find("\"running\":false") != std::string::npos &&
               state.json.find("token") == std::string::npos,
           "E5.30 controller status defaults off without token");
    controller.Stop();
    controller.Stop();
    Expect(controller.Status().ok(), "E5.30 controller stop is idempotent");
    bool shutdownHookCalled = false;
    isolated.SetRemoteStopHook([&] { shutdownHookCalled = true; });
    isolated.StopCoreProcess();
    Expect(shutdownHookCalled, "E5.30 core stop invokes remote shutdown hook");
    shutdownHookCalled = false;
    isolated.SetRemoteStopHook(nullptr);
    isolated.StopCoreProcess();
    Expect(!shutdownHookCalled, "E5.30 remote shutdown hook can be cleared");
  }
  for (const std::string state : {"awaiting_approval", "done", "failed",
                                  "audit_unavailable", "budget_blocked"}) {
    Expect(!beats::notifications::Title(state).empty(),
           "E5.29 five notification states have native title");
    Expect(beats::notifications::ShouldNotify(state, false),
           "E5.29 no-focus state notifies");
    Expect(!beats::notifications::ShouldNotify(state, true),
           "E5.29 focused window suppresses native balloon");
    const auto info = beats::notifications::Balloon(nullptr, 42, state);
    Expect(info.uFlags == NIF_INFO && wcsstr(info.szInfo, L"#42"),
           "E5.29 NIF_INFO targets order");
  }
  Expect(!beats::notifications::ShouldNotify("running", false),
         "E5.29 unsupported state does not notify");
  unsigned port = 1;
  std::string origin;
  Expect(beats::RemoteController::Options("{}", port, origin) && port == 0 &&
             origin.empty(),
         "E5.30 default random port");
  Expect(beats::RemoteController::Options(
             "{\"port\":9334,\"origin\":\"https://example.test\"}", port,
             origin) &&
             port == 9334,
         "E5.30 explicit tunnel origin");
  for (const std::string bad :
       {"{\"port\":-1}", "{\"port\":65536}", "{\"port\":1.5}",
        "{\"port\":\"5\"}", "{\"host\":\"0.0.0.0\"}",
        "{\"origin\":\"https://bad.test\\\" --host 0.0.0.0\"}",
        "{\"origin\":\"javascript:alert(1)\"}", "null", "{"})
    Expect(!beats::RemoteController::Options(bad, port, origin),
           "E5.30 invalid launch options rejected");
  const std::string tokenFixture(64, 'a');
  const std::string startup =
      "{\"url\":\"http://127.0.0.1:12345\",\"token\":\"" + tokenFixture + "\"}";
  std::string startupUrl;
  Expect(beats::RemoteController::Startup(startup, startupUrl) &&
             startupUrl == "http://127.0.0.1:12345",
         "E5.30 secure child startup parsed");
  Expect(
      !beats::RemoteController::Startup(
          "{\"url\":\"http://127.0.0.1:1\",\"token\":\"short\"}", startupUrl),
      "E5.30 short token rejected");
  Expect(!beats::RemoteController::Startup(
             ReplaceOne(startup, "127.0.0.1", "0.0.0.0"), startupUrl),
         "E5.30 non-loopback child URL rejected");
  Expect(!beats::RemoteController::Startup(ReplaceOne(startup, "12345", "0"),
                                           startupUrl),
         "E5.30 zero startup port rejected");
  Expect(!beats::RemoteController::Startup(
             ReplaceOne(startup, "12345", "99999"), startupUrl),
         "E5.30 excessive startup port rejected");
  Expect(!beats::RemoteController::Startup(
             ReplaceOne(startup, "12345", "1/path"), startupUrl),
         "E5.30 extra startup path rejected");
  Expect(
      !beats::RemoteController::Startup(
          ReplaceOne(startup, tokenFixture, std::string(64, 'g')), startupUrl),
      "E5.30 non-hex token rejected");
  Expect(!beats::RemoteController::Startup(startup + "{}", startupUrl),
         "E5.30 extra startup document rejected");
  PreviewTests();
  MainViewPolicyTests();
  MainViewLifecycleTests();
  // -- ParseOpenWindow: vistas validas ------------------------------------
  {
    auto r = beats::ParseOpenWindow(
        "{\"vista\":\"editor\",\"path\":\"C:\\\\tmp\\\\a.txt\"}");
    // GetStringProp desescapa JSON: "C:\\tmp\\a.txt" -> C:\tmp\a.txt
    Expect(r.valid && r.vista == "editor" && r.path == "C:\\tmp\\a.txt",
           "editor con path valido");
  }
  {
    auto r = beats::ParseOpenWindow("{\"vista\":\"terminal\"}");
    Expect(r.valid && r.vista == "terminal", "terminal sin parametros");
  }
  {
    auto r = beats::ParseOpenWindow("{\"vista\":\"monitor\"}");
    Expect(r.valid, "monitor sin parametros");
  }
  {
    auto r =
        beats::ParseOpenWindow("{\"vista\":\"conversacion\",\"order_id\":42}");
    Expect(r.valid && r.orderId == 42, "conversacion con order_id numerico");
  }
  {
    auto r = beats::ParseOpenWindow(
        "{\"vista\":\"conversacion\",\"orderId\":\"7\"}");
    Expect(r.valid && r.orderId == 7, "conversacion con orderId string");
  }

  // -- ParseOpenWindow: rechazos -------------------------------------------
  {
    auto r = beats::ParseOpenWindow("{\"vista\":\"explorer\"}");
    Expect(!r.valid && !r.error.empty(), "vista desconocida rechazada");
  }
  {
    auto r = beats::ParseOpenWindow("{\"vista\":\"editor\"}");
    Expect(!r.valid, "editor sin path rechazado");
  }
  {
    // CAB031-r2: el botón real de la conversación envía este payload cuando
    // todavía no hay una orden abierta. La ventana debe abrir el chat vacío,
    // no quedarse sin abrir (el popout del Monitor ya no exige orden).
    auto r = beats::ParseOpenWindow("{\"vista\":\"conversacion\"}");
    Expect(r.valid && r.orderId == 0, "conversacion sin orden abre chat vacio");
  }
  {
    auto r = beats::ParseOpenWindow("{}");
    Expect(!r.valid, "payload sin vista rechazado");
  }
  {
    auto r = beats::ParseOpenWindow(
        "{\"vista\":\"editor\",\"path\":\"a\\\"b.txt\"}");
    Expect(!r.valid, "path con comillas rechazado");
  }
  {
    auto r =
        beats::ParseOpenWindow("{\"vista\":\"editor\",\"path\":\"a%20b.txt\"}");
    Expect(!r.valid, "path con % (inyeccion de query) rechazado");
  }
  {
    auto r =
        beats::ParseOpenWindow("{\"vista\":\"editor\",\"path\":\"a#b.txt\"}");
    Expect(!r.valid, "path con # rechazado");
  }
  {
    // JSON \b -> backspace 0x08: visto en vivo al escapar mal la ruta —
    // navegaba a una URL con %08 incrustado.
    auto r =
        beats::ParseOpenWindow("{\"vista\":\"editor\",\"path\":\"a\bb.txt\"}");
    Expect(!r.valid, "path con control \\b rechazado");
  }
  {
    auto r =
        beats::ParseOpenWindow("{\"vista\":\"editor\",\"path\":\"a\tb.txt\"}");
    Expect(!r.valid, "path con control \\t rechazado");
  }

  // -- alias tolerado `view` ------------------------------------------------
  {
    auto r = beats::ParseOpenWindow("{\"view\":\"monitor\"}");
    Expect(r.valid && r.vista == "monitor", "alias view aceptado");
  }

  // -- UrlEncodeComponent ---------------------------------------------------
  {
    const std::string path = "C:\\tmp dir\\a.txt";
    const std::wstring enc = beats::WindowSupervisor::UrlEncodeComponent(path);
    // '\' y ':' pasan tal cual; el espacio se codifica.
    Expect(enc.find(L' ') == std::wstring::npos &&
               enc.find(L"%20") != std::wstring::npos,
           "UrlEncode codifica espacios");
    Expect(enc.find(L'\\') != std::wstring::npos,
           "UrlEncode conserva backslash (ruta intacta en query)");
    Expect(enc.find(L'"') == std::wstring::npos, "UrlEncode nunca emite '\"'");
  }

  // -- Supervisor vacio -------------------------------------------------------
  {
    beats::WindowSupervisor sup;
    Expect(sup.ByHwnd(reinterpret_cast<HWND>(0x1234)) == nullptr,
           "ByHwnd sobre registro vacio -> nullptr");
    Expect(sup.Primary() == nullptr, "Primary vacio -> nullptr");
    Expect(sup.All().empty(), "All vacio");
  }

  std::printf("\n%d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
