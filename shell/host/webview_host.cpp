// Shared implementation is included by the structural COM doubles without
// compiling the host twice; this keeps the seam in the authorized .cpp file.
#ifndef BEATS_WEBVIEW_INITIALIZATION_SHARED
#define BEATS_WEBVIEW_INITIALIZATION_SHARED
#include "webview_host.hpp"
#include "themed_dialog.hpp"
#include <functional>
#include <vector>

namespace beats::webview_init {
class Subscriptions {
  std::vector<std::function<HRESULT()>> m_remove;

public:
  Subscriptions() = default;
  Subscriptions(const Subscriptions &) = delete;
  Subscriptions &operator=(const Subscriptions &) = delete;
  template <class View, class Add, class Remove, class Handler>
  HRESULT AddHandler(View *view, Add add, Remove remove, Handler *handler) {
    EventRegistrationToken token{};
    const HRESULT hr = (view->*add)(handler, &token);
    handler->Release();
    if (FAILED(hr))
      return hr;
    view->AddRef();
    m_remove.emplace_back([view, remove, token]() {
      const HRESULT hr = (view->*remove)(token);
      view->Release();
      return hr;
    });
    return S_OK;
  }
  HRESULT Clear() {
    HRESULT first = S_OK;
    for (auto it = m_remove.rbegin(); it != m_remove.rend(); ++it) {
      const HRESULT hr = (*it)();
      if (FAILED(hr) && SUCCEEDED(first))
        first = hr;
    }
    m_remove.clear();
    return first;
  }
};

template <class Initialize, class Abort, class Report>
HRESULT Run(Initialize initialize, Abort abort, Report report) {
  const HRESULT hr = initialize();
  if (FAILED(hr)) {
    abort();
    report(hr);
  }
  return hr;
}

template <class Controller, class Controller2>
HRESULT ConfigureController(Controller *controller, Controller2 *controller2) {
  COREWEBVIEW2_COLOR background = {255, 10, 10, 10};
  const HRESULT hr = controller2->put_DefaultBackgroundColor(background);
  if (FAILED(hr))
    return hr;
  return controller->put_IsVisible(TRUE);
}

struct ReleaseCom {
  template <class T> void operator()(T *value) const { value->Release(); }
};

template <class View, class View2, class Navigation, class Process, class Dom>
HRESULT Start(View *view, View2 *view2, Navigation *navigation,
              Process *process, Dom *dom, const wchar_t *url,
              Subscriptions &subscriptions) {
  std::unique_ptr<Navigation, ReleaseCom> navOwner(navigation);
  std::unique_ptr<Process, ReleaseCom> processOwner(process);
  std::unique_ptr<Dom, ReleaseCom> domOwner(dom);
  HRESULT hr = subscriptions.AddHandler(view, &View::add_NavigationCompleted,
                                        &View::remove_NavigationCompleted,
                                        navOwner.release());
  if (FAILED(hr))
    return hr;
  hr = subscriptions.AddHandler(view, &View::add_ProcessFailed,
                                &View::remove_ProcessFailed,
                                processOwner.release());
  if (FAILED(hr))
    return hr;
  hr = subscriptions.AddHandler(view2, &View2::add_DOMContentLoaded,
                                &View2::remove_DOMContentLoaded,
                                domOwner.release());
  if (FAILED(hr))
    return hr;
  return view->Navigate(url);
}
} // namespace beats::webview_init
#endif

#ifndef BEATS_WEBVIEW_INITIALIZATION_ONLY
#include "origin_policy.hpp"
#include "preview_policy.hpp"
#include "preview_selector.hpp"
#include "shell_policy.hpp"
#include "version_runtime.hpp"
#include "webview_policy.hpp"
#include <fstream>
#include <iostream>
#include <locale>
#include <shlobj.h>
#include <sstream>
#include <unordered_map>

namespace beats {

static std::wstring Utf8ToWide(const std::string &str) {
  if (str.empty())
    return L"";
  int size =
      MultiByteToWideChar(CP_UTF8, 0, str.c_str(), (int)str.size(), NULL, 0);
  std::wstring wstr(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, str.c_str(), (int)str.size(), &wstr[0], size);
  return wstr;
}

// Registros en %LOCALAPPDATA%\DevAgents-Angel\logs (Angel, 8-nov; antes
// \DevAgents). Hasta el 22-09 iban a C:\tmp, que en la maquina del dueno NO
// existe: fopen fallaba en silencio y las muertes del renderer, las
// navegaciones fallidas y la rendicion «queda en blanco» no dejaban rastro. Una
// pantalla blanca sin registro no se caza.
static std::string LogPath(const char *name) {
  static std::string dir;
  if (dir.empty()) {
    // Native test drivers redirect logs to their own fixture; JS cannot set it.
    const char *fixtureDir = std::getenv("BEATS_WEBVIEW_LOG_DIR");
    if (fixtureDir && *fixtureDir) {
      dir = fixtureDir;
      return dir + "\\" + name;
    }
    char base[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathA(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, base))) {
      std::string d = std::string(base) + "\\DevAgents-Angel";
      CreateDirectoryA(d.c_str(), nullptr);
      d += "\\logs";
      CreateDirectoryA(d.c_str(), nullptr);
      dir = d;
    } else {
      dir = ".";
    }
  }
  return dir + "\\" + name;
}

static void LogWV(const std::string &msg) {
  FILE *f = nullptr;
  if (fopen_s(&f, LogPath("webview.log").c_str(), "a") == 0 && f) {
    fputs(msg.c_str(), f);
    fputs("\n", f);
    fclose(f);
  }
}

// Preview diagnostics go to the debugger and captured stderr, never owner data.
static void LogPreview(const std::string &message) {
  OutputDebugStringA((message + "\n").c_str());
  std::cerr << message << std::endl;
}

// 1. Environment Completed Handler
class EnvCompletedHandler
    : public ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler {
public:
  WebViewHost *host;
  std::wstring bundleDir;
  bool enableDevTools;
  ULONG ref = 1;

  EnvCompletedHandler(WebViewHost *h, const std::wstring &dir, bool dev)
      : host(h), bundleDir(dir), enableDevTools(dev) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid ==
            IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler) {
      *ppv = static_cast<
          ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE
  Invoke(HRESULT result, ICoreWebView2Environment *env) override;
};

// 2. Controller Completed Handler
class ControllerCompletedHandler
    : public ICoreWebView2CreateCoreWebView2ControllerCompletedHandler {
public:
  WebViewHost *host;
  std::wstring bundleDir;
  bool enableDevTools;
  ULONG ref = 1;

  ControllerCompletedHandler(WebViewHost *h, const std::wstring &dir, bool dev)
      : host(h), bundleDir(dir), enableDevTools(dev) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler) {
      *ppv = static_cast<
          ICoreWebView2CreateCoreWebView2ControllerCompletedHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE
  Invoke(HRESULT result, ICoreWebView2Controller *controller) override;
};

// 3. WebMessageReceived Event Handler
class WebMessageReceivedHandler
    : public ICoreWebView2WebMessageReceivedEventHandler {
public:
  WebViewHost *host;
  ULONG ref = 1;

  WebMessageReceivedHandler(WebViewHost *h) : host(h) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == IID_ICoreWebView2WebMessageReceivedEventHandler) {
      *ppv = static_cast<ICoreWebView2WebMessageReceivedEventHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2 *sender,
         ICoreWebView2WebMessageReceivedEventArgs *args) override {
    if (!args)
      return E_POINTER;
    wchar_t *source = nullptr;
    const HRESULT sourceHr = args->get_Source(&source);
    const bool trusted =
        SUCCEEDED(sourceHr) && source && security::IsAppOrigin(source);
    if (source)
      CoTaskMemFree(source);
    if (!trusted) {
      // Never parse or dispatch a message from a document outside our origin.
      LogWV("[Bridge] rejected message from an untrusted origin");
      return S_OK;
    }
    wchar_t *msg = nullptr;
    HRESULT hr = args->TryGetWebMessageAsString(&msg);
    if (FAILED(hr) || !msg) {
      args->get_WebMessageAsJson(&msg);
    }
    if (msg) {
      if (!WebViewHost::MessageWithinBound(
              wcsnlen_s(msg, WebViewHost::BridgeMessageLimit + 1))) {
        LogPreview("[Bridge] inbound message exceeds 28 MiB before conversion");
      } else if (host->GetMessageCallback()) {
        host->GetMessageCallback()(msg);
      }
      CoTaskMemFree(msg);
    }
    return S_OK;
  }
};

static std::string UnquoteJsonString(const std::string &raw) {
  if (raw.size() >= 2 && raw.front() == '"' && raw.back() == '"') {
    std::string unquoted;
    unquoted.reserve(raw.size());
    for (size_t i = 1; i < raw.size() - 1; ++i) {
      if (raw[i] == '\\' && i + 1 < raw.size() - 1) {
        char next = raw[i + 1];
        if (next == '"' || next == '\\' || next == '/') {
          unquoted += next;
          ++i;
          continue;
        } else if (next == 'n') {
          unquoted += '\n';
          ++i;
          continue;
        } else if (next == 'r') {
          unquoted += '\r';
          ++i;
          continue;
        } else if (next == 't') {
          unquoted += '\t';
          ++i;
          continue;
        }
      }
      unquoted += raw[i];
    }
    return unquoted;
  }
  return raw;
}

static std::wstring PathToFileUri(const std::wstring &absPath) {
  std::wstring uri = L"file:///";
  for (wchar_t ch : absPath) {
    if (ch == L'\\') {
      uri += L'/';
    } else if (ch == L' ') {
      uri += L"%20";
    } else {
      uri += ch;
    }
  }
  return uri;
}

// 4. NavigationCompleted Event Handler
class ExecuteScriptCompletedHandler
    : public ICoreWebView2ExecuteScriptCompletedHandler {
public:
  std::string *outResult;
  HANDLE hEvent;
  ULONG ref = 1;

  ExecuteScriptCompletedHandler(std::string *out, HANDLE evt)
      : outResult(out), hEvent(evt) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == IID_ICoreWebView2ExecuteScriptCompletedHandler) {
      *ppv = static_cast<ICoreWebView2ExecuteScriptCompletedHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE Invoke(HRESULT error,
                                           LPCWSTR resultJson) override {
    LogWV("[ExecuteScript] Invoke called with error=" + std::to_string(error));
    if (SUCCEEDED(error) && resultJson) {
      int size_needed =
          WideCharToMultiByte(CP_UTF8, 0, resultJson, -1, NULL, 0, NULL, NULL);
      if (size_needed > 1) {
        std::string str(size_needed - 1, 0);
        WideCharToMultiByte(CP_UTF8, 0, resultJson, -1, &str[0], size_needed,
                            NULL, NULL);
        std::string cleanJson = UnquoteJsonString(str);
        const std::string dumpPath = LogPath("beats_cdp_dump.json");
        LogWV("[ExecuteScript] Writing DOM diagnostics");
        FILE *f = nullptr;
        if (fopen_s(&f, dumpPath.c_str(), "w") == 0 && f) {
          fputs(cleanJson.c_str(), f);
          fclose(f);
        }
      }
    }
    if (hEvent)
      SetEvent(hEvent);
    return S_OK;
  }
};

template <class Interface, class... Args>
class PreviewHandler final : public Interface {
  GUID m_iid;
  ULONG m_ref = 1;
  std::function<HRESULT(Args...)> m_callback;

public:
  PreviewHandler(REFIID iid, std::function<HRESULT(Args...)> callback)
      : m_iid(iid), m_callback(std::move(callback)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **out) override {
    if (!out)
      return E_POINTER;
    *out = nullptr;
    if (iid != IID_IUnknown && iid != m_iid)
      return E_NOINTERFACE;
    *out = static_cast<Interface *>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&m_ref);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG n = InterlockedDecrement(&m_ref);
    if (!n)
      delete this;
    return n;
  }
  HRESULT STDMETHODCALLTYPE Invoke(Args... args) override {
    return m_callback(args...);
  }
};
class NavStartingHandler : public ICoreWebView2NavigationStartingEventHandler {
public:
  WebViewHost *host;
  ULONG ref = 1;

  NavStartingHandler(WebViewHost *h) : host(h) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == IID_ICoreWebView2NavigationStartingEventHandler) {
      *ppv = static_cast<ICoreWebView2NavigationStartingEventHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2 *sender,
         ICoreWebView2NavigationStartingEventArgs *args) override {
    if (!args)
      return E_POINTER;
    wchar_t *uri = nullptr;
    const HRESULT hr = args->get_Uri(&uri);
    const bool trusted = SUCCEEDED(hr) && uri && security::IsAppOrigin(uri);
    if (uri)
      CoTaskMemFree(uri);
    // The same gate covers main documents and frames, including redirects.
    if (!trusted) {
      LogWV("[NavStarting] rejected navigation outside the app origin");
      return args->put_Cancel(TRUE);
    }
    return S_OK;
  }
};

class NewWindowHandler : public ICoreWebView2NewWindowRequestedEventHandler {
  ULONG ref = 1;

public:
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
    if (!out)
      return E_POINTER;
    *out = nullptr;
    if (riid != IID_IUnknown &&
        riid != IID_ICoreWebView2NewWindowRequestedEventHandler)
      return E_NOINTERFACE;
    *out = static_cast<ICoreWebView2NewWindowRequestedEventHandler *>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    const ULONG count = InterlockedDecrement(&ref);
    if (!count)
      delete this;
    return count;
  }
  HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2 *,
         ICoreWebView2NewWindowRequestedEventArgs *args) override {
    if (!args)
      return E_POINTER;
    // Claim every popup first: no external document ever inherits our bridge.
    const HRESULT hr = args->put_Handled(TRUE);
    if (FAILED(hr))
      return hr;
    wchar_t *uri = nullptr;
    if (SUCCEEDED(args->get_Uri(&uri)) && uri && !security::IsAppOrigin(uri) &&
        security::IsBrowserUrl(uri, true)) {
      if (!security::OpenBrowserUrl(uri, true))
        LogWV("[NewWindow] system browser launch failed");
    } else {
      LogWV("[NewWindow] popup rejected");
    }
    if (uri)
      CoTaskMemFree(uri);
    return S_OK;
  }
};

class NavCompletedHandler
    : public ICoreWebView2NavigationCompletedEventHandler {
public:
  WebViewHost *host;
  ULONG ref = 1;

  NavCompletedHandler(WebViewHost *h) : host(h) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    wchar_t guidStr[64] = {0};
    StringFromGUID2(riid, guidStr, 64);
    std::wstring wsGuid(guidStr);
    LogWV("[NavCompleted QueryInterface] riid=" +
          std::string(wsGuid.begin(), wsGuid.end()));
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == IID_ICoreWebView2NavigationCompletedEventHandler) {
      *ppv = static_cast<ICoreWebView2NavigationCompletedEventHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2 *sender,
         ICoreWebView2NavigationCompletedEventArgs *args) override {
    BOOL isSuccess = FALSE;
    COREWEBVIEW2_WEB_ERROR_STATUS status =
        COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
    if (args) {
      args->get_IsSuccess(&isSuccess);
      args->get_WebErrorStatus(&status);
    }
    LogWV("[NavCompleted] IsSuccess=" + std::to_string(isSuccess) +
          " WebErrorStatus=" + std::to_string(status));
    // Una navegación buena resetea el contador de crash→reload: solo
    // las muertes en ráfaga cortan la recuperación.
    if (isSuccess) {
      host->NoteNavigationSucceeded();
    } else if (status != COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED &&
               !host->NoteCrashForReload()) {
      // Rafaga agotada: antes se abandonaba aqui y la ventana quedaba en
      // blanco para siempre. Ahora se reintenta con espera creciente.
      host->ScheduleRecovery(false);
      return S_OK;
    } else if (status != COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED) {
      // Con IsBuiltInErrorPageEnabled=FALSE una navegación fallida deja la
      // página en BLANCO puro y permanente (mismo síntoma que un crash del
      // renderer). Reintento acotado por el mismo contador que ProcessFailed;
      // OPERATION_CANCELED (el usuario abortó la navegación) no se reintenta.
      LogWV("[NavCompleted] navegación fallida; recargando");
      sender->Reload();
      return S_OK;
    }
    auto now = std::chrono::high_resolution_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                  now - host->GetStartTime())
                  .count();
    std::string logMsg =
        "[DEVAGENTS_PERF] Cold Startup Time: " + std::to_string(ms) + " ms\n";
    std::cout << logMsg << std::flush;
    OutputDebugStringA(logMsg.c_str());

    FILE *f = nullptr;
    if (fopen_s(&f, LogPath("perf.log").c_str(), "a") == 0 && f) {
      fputs(logMsg.c_str(), f);
      fclose(f);
    }

#ifndef NDEBUG
    sender->ExecuteScript(
        L"JSON.stringify({\n"
        L"  title: document.title,\n"
        L"  innerText: document.body.innerText,\n"
        L"  url: window.location.href,\n"
        L"  ids: Array.from(document.querySelectorAll('[id]')).map(e => e.id)\n"
        L"})",
        new ExecuteScriptCompletedHandler(nullptr, nullptr));
#endif

    return S_OK;
  }
};

// recuperación de muerte del renderer. Antes no había handler de
// ProcessFailed: un crash del proceso de render (OOM con una orden larga,
// GPU…) dejaba el WebView en blanco puro y PERMANENTE — la única salida era
// cerrar y reabrir la aplicación. WebView2 no recarga por sí solo: hay que
// responder al evento. Los kinds de frame/renderer/utilidad se recuperan
// con Reload(); BROWSER_PROCESS_EXITED tumba el WebView entero y no hay
// sender usable — solo queda registrado en el log.
class ProcessFailedHandler : public ICoreWebView2ProcessFailedEventHandler {
public:
  WebViewHost *host;
  ULONG ref = 1;

  explicit ProcessFailedHandler(WebViewHost *h) : host(h) {}

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == IID_ICoreWebView2ProcessFailedEventHandler) {
      *ppv = static_cast<ICoreWebView2ProcessFailedEventHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2 *sender,
         ICoreWebView2ProcessFailedEventArgs *args) override {
    COREWEBVIEW2_PROCESS_FAILED_KIND kind =
        COREWEBVIEW2_PROCESS_FAILED_KIND_UNKNOWN_PROCESS_EXITED;
    COREWEBVIEW2_PROCESS_FAILED_REASON reason =
        COREWEBVIEW2_PROCESS_FAILED_REASON_UNEXPECTED;
    if (args) {
      args->get_ProcessFailedKind(&kind);
      ICoreWebView2ProcessFailedEventArgs2 *args2 = nullptr;
      if (SUCCEEDED(
              args->QueryInterface(IID_ICoreWebView2ProcessFailedEventArgs2,
                                   reinterpret_cast<void **>(&args2))) &&
          args2) {
        args2->get_Reason(&reason);
        args2->Release();
      }
    }
    LogWV("[ProcessFailed] kind=" + std::to_string(kind) +
          " reason=" + std::to_string(reason));
    if (!host)
      return S_OK;
    // Muerto el proceso de navegador, este WebView ya no sirve: antes solo se
    // registraba y la ventana quedaba en blanco con el host vivo — el sintoma
    // que reporto el dueno el 22-09. Se recrea entero (entorno + controlador).
    if (kind == COREWEBVIEW2_PROCESS_FAILED_KIND_BROWSER_PROCESS_EXITED) {
      LogWV(
          "[ProcessFailed] proceso de navegador muerto; se recrea el WebView");
      host->ScheduleRecovery(true);
      return S_OK;
    }
    if (!sender)
      return S_OK;
    if (!host->NoteCrashForReload()) {
      LogWV("[ProcessFailed] rafaga de recargas agotada; reintento diferido");
      host->ScheduleRecovery(false);
      return S_OK;
    }
    LogWV("[ProcessFailed] recargando la página tras la muerte del proceso");
    sender->Reload();
    return S_OK;
  }
};

class DOMContentLoadedHandler
    : public ICoreWebView2DOMContentLoadedEventHandler {
public:
  WebViewHost *host;
  ULONG ref = 1;
  DOMContentLoadedHandler(WebViewHost *h) : host(h) {}
  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown ||
        riid == IID_ICoreWebView2DOMContentLoadedEventHandler) {
      *ppv = static_cast<ICoreWebView2DOMContentLoadedEventHandler *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }
  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }
  virtual HRESULT STDMETHODCALLTYPE
  Invoke(ICoreWebView2 *sender,
         ICoreWebView2DOMContentLoadedEventArgs *args) override {
#ifndef NDEBUG
    sender->ExecuteScript(
        L"JSON.stringify({ title: document.title, innerText: "
        L"document.body.innerText, ids: "
        L"Array.from(document.querySelectorAll('[id]')).map(e => e.id) })",
        new ExecuteScriptCompletedHandler(nullptr, nullptr));
#endif
    return S_OK;
  }
};

// -- Entorno compartido (E5.21) ---------------------------------------------
// Todas las ventanas del proceso usan el MISMO ICoreWebView2Environment sobre
// la misma carpeta de perfil: así la segunda ventana no dispara un segundo
// navegador ni un segundo perfil, y una sesión (localStorage, caché) se ve
// igual en todas. La creación es asíncrona: las ventanas que llegan mientras
// el entorno se crea quedan encoladas y se montan al completarse.
static ICoreWebView2Environment *s_sharedEnv = nullptr;
static bool s_envInFlight = false;
static std::wstring s_envKey; // userDataDir + args: otro combo = otro entorno
static std::vector<WebViewHost *> s_envPending;

static void CreateControllerOnEnv(ICoreWebView2Environment *env,
                                  WebViewHost *host,
                                  const std::wstring &bundleDir,
                                  bool enableDevTools) {
  env->CreateCoreWebView2Controller(
      host->GetParentHwnd(),
      new ControllerCompletedHandler(host, bundleDir, enableDevTools));
}

HRESULT STDMETHODCALLTYPE
EnvCompletedHandler::Invoke(HRESULT result, ICoreWebView2Environment *env) {
  LogWV("[EnvCompleted] Invoke called with result=0x" + std::to_string(result));
  if (FAILED(result) || !env) {
    s_envInFlight = false;
    s_envPending.clear();
    std::cout << "[DEVAGENTS_WEBVIEW] EnvCompleted failed with hr = 0x"
              << std::hex << result << std::endl;
    wchar_t buf[256];
    swprintf_s(buf,
               L"Error al inicializar WebView2 Environment. HRESULT: 0x%08X",
               result);
    themed::Show(host->GetParentHwnd(), L"No se pudo abrir la interfaz", buf,
                 themed::Kind::error, themed::Buttons::ok);
    return result;
  }
  std::cout << "[DEVAGENTS_WEBVIEW] EnvCompleted succeeded" << std::endl;
  // E5.21: se guarda el entorno y se despierta a las ventanas que esperaban.
  s_sharedEnv = env;
  s_sharedEnv->AddRef();
  s_envInFlight = false;
  CreateControllerOnEnv(env, host, bundleDir, enableDevTools);
  for (WebViewHost *pending : s_envPending) {
    CreateControllerOnEnv(env, pending, pending->GetInitBundleDir(),
                          pending->GetInitDevTools());
  }
  s_envPending.clear();
  return S_OK;
}

// The public host header is outside this delivery's edit scope. Keep event
// ownership here, keyed by the host, and erase it before Close/recreation.
static std::unordered_map<WebViewHost *, webview_init::Subscriptions> &
MainSubscriptions() {
  static std::unordered_map<WebViewHost *, webview_init::Subscriptions> entries;
  return entries;
}

static void ClearMainSubscriptions(WebViewHost *host) {
  auto &entries = MainSubscriptions();
  const auto it = entries.find(host);
  if (it == entries.end())
    return;
  const HRESULT hr = it->second.Clear();
  if (FAILED(hr))
    LogWV("[WebView2] handler removal failed hr=" + std::to_string(hr));
  entries.erase(it);
}

static void ReportInitializationError(WebViewHost *host, HRESULT hr) {
  LogWV("[WebView2] initialization aborted hr=" + std::to_string(hr));
  wchar_t message[256];
  swprintf_s(message, L"No se pudo inicializar WebView2. HRESULT: 0x%08X",
             static_cast<unsigned int>(hr));
  themed::Show(host->GetParentHwnd(), L"No se pudo abrir la interfaz", message,
               themed::Kind::error, themed::Buttons::ok);
}

HRESULT STDMETHODCALLTYPE ControllerCompletedHandler::Invoke(
    HRESULT result, ICoreWebView2Controller *controller) {
  LogWV("[ControllerCompleted] Invoke called with result=0x" +
        std::to_string(result));
  if (FAILED(result) || !controller) {
    std::cout << "[DEVAGENTS_WEBVIEW] ControllerCompleted failed with hr = 0x"
              << std::hex << result << std::endl;
    wchar_t buf[512];
    // 0x8007139F (ERROR_INVALID_STATE): otra cabina usa la misma carpeta de
    // datos con opciones distintas. Un código hexadecimal no le dice nada al
    // usuario; esto sí.
    if (result == static_cast<HRESULT>(0x8007139F))
      swprintf_s(buf,
                 L"Ya hay otra ventana de DevAgents abierta con una "
                 L"configuración distinta (por ejemplo, con depuración). "
                 L"Ciérrala y vuelve a abrir DevAgents.\n\nHRESULT: 0x%08X",
                 result);
    else
      swprintf_s(buf, L"Error al crear Controller WebView2. HRESULT: 0x%08X",
                 result);
    themed::Show(host->GetParentHwnd(), L"No se pudo abrir la interfaz", buf,
                 themed::Kind::error, themed::Buttons::ok);
    return FAILED(result) ? result : E_POINTER;
  }
  std::cout << "[DEVAGENTS_WEBVIEW] ControllerCompleted succeeded" << std::endl;

  return webview_init::Run(
      [&]() -> HRESULT {
        auto now = std::chrono::high_resolution_clock::now();
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                      now - host->GetStartTime())
                      .count();
        std::string logMsg =
            "[DEVAGENTS_PERF] Cold Startup Time: " + std::to_string(ms) +
            " ms\n";
        std::cout << logMsg << std::flush;
        OutputDebugStringA(logMsg.c_str());

        std::ofstream fLog(LogPath("perf.log"), std::ios::out | std::ios::app);
        if (fLog.is_open()) {
          fLog << logMsg;
          fLog.flush();
        }

        ClearMainSubscriptions(host);
        host->SetController(controller);
        auto &subscriptions = MainSubscriptions()[host];

        // Fondo del WebView mientras no hay documento pintado (arranque,
        // recarga, renderer caido). Era el blanco por defecto de WebView2: cada
        // recarga era un fogonazo blanco y cualquier fallo, una pantalla
        // blanca. Es el fondo del tema por defecto (#0A0A0A).
        ICoreWebView2Controller2 *controller2 = nullptr;
        const HRESULT controller2Hr =
            controller->QueryInterface(IID_ICoreWebView2Controller2,
                                       reinterpret_cast<void **>(&controller2));
        if (FAILED(controller2Hr) || !controller2)
          return FAILED(controller2Hr) ? controller2Hr : E_NOINTERFACE;
        const HRESULT appearanceHr =
            webview_init::ConfigureController(controller, controller2);
        controller2->Release();
        if (FAILED(appearanceHr))
          return appearanceHr;

        ICoreWebView2 *webView = nullptr;
        const HRESULT viewHr = controller->get_CoreWebView2(&webView);
        if (FAILED(viewHr) || !webView)
          return FAILED(viewHr) ? viewHr : E_POINTER;
        host->SetWebView(webView);

        RECT bounds;
        GetClientRect(host->GetParentHwnd(), &bounds);
        host->Resize(bounds.right, bounds.bottom);

        if (host->IsPreview()) {
          const HRESULT previewHr =
              host->InitializePreview(webView, enableDevTools);
          webView->Release();
          if (FAILED(previewHr))
            LogPreview("[Preview] initialization failed hr=" +
                       std::to_string(previewHr));
          return previewHr;
        }

        // Reject the exact directory about to be mapped, including absent
        // manifests.
        const auto versionError =
            versions::Mismatch("WebUI", versions::WebUiIdentity(bundleDir));
        if (!versionError.empty()) {
          LogWV("[CK-COMP-004] " + versionError);
          const auto page = Utf8ToWide(versions::Html(versionError));
          const HRESULT result = webView->NavigateToString(page.c_str());
          webView->Release();
          return result;
        }

        ICoreWebView2_3 *webView3 = nullptr;
        HRESULT hrQI = webView->QueryInterface(
            IID_ICoreWebView2_3, reinterpret_cast<void **>(&webView3));
        LogWV("[QueryInterface ICoreWebView2_3] hr=0x" + std::to_string(hrQI));
        if (SUCCEEDED(hrQI) && webView3) {
          wchar_t absBundlePath[MAX_PATH];
          GetFullPathNameW(bundleDir.c_str(), MAX_PATH, absBundlePath, NULL);
          std::wstring wsPath(absBundlePath);
          std::string sPath(wsPath.begin(), wsPath.end());
          LogWV("[SetVirtualHostNameToFolderMapping] absBundlePath=" + sPath);
          HRESULT hrMap = webView3->SetVirtualHostNameToFolderMapping(
              L"devagents.local", absBundlePath,
              COREWEBVIEW2_HOST_RESOURCE_ACCESS_KIND_ALLOW);
          LogWV("[SetVirtualHostNameToFolderMapping] hr=0x" +
                std::to_string(hrMap));
          webView3->Release();
          if (FAILED(hrMap)) {
            webView->Release();
            return hrMap;
          }
        } else {
          // Without the local mapping, the app URL must never fall back to DNS.
          webView->Release();
          return FAILED(hrQI) ? hrQI : E_NOINTERFACE;
        }

        ICoreWebView2Settings *settings = nullptr;
        const HRESULT settingsHr = webView->get_Settings(&settings);
        if (SUCCEEDED(settingsHr) && settings) {
          BOOL devToolsActive = FALSE;
#ifndef NDEBUG
          devToolsActive = enableDevTools ? TRUE : FALSE;
          const char *devToolsEnv = std::getenv("DEVAGENTS_DEVTOOLS_PORT");
          if (!devToolsEnv || std::string(devToolsEnv) == "") {
            devToolsEnv = std::getenv("BEATS_DEVTOOLS_PORT");
          }
          if (devToolsEnv && std::string(devToolsEnv) != "") {
            devToolsActive = TRUE;
          }
#endif

          // Un ajuste que falla no puede dejar el valor por defecto de WebView2
          // (diálogos de script, menús, DevTools): se aborta el arranque.
          const HRESULT settingsApplied = webview_policy::ApplyMainViewSettings(
              settings, devToolsActive != FALSE);
          if (FAILED(settingsApplied)) {
            LogWV("[Settings] main view settings failed hr=0x" +
                  std::to_string(settingsApplied));
            settings->Release();
            webView->Release();
            return settingsApplied;
          }
          settings->Release();
        } else {
          // A failed settings call cannot leave release with the default
          // DevTools.
          webView->Release();
          return FAILED(settingsHr) ? settingsHr : E_FAIL;
        }

        auto *message = new WebMessageReceivedHandler(host);
        HRESULT gateHr = subscriptions.AddHandler(
            webView, &ICoreWebView2::add_WebMessageReceived,
            &ICoreWebView2::remove_WebMessageReceived, message);
        if (FAILED(gateHr)) {
          webView->Release();
          return gateHr;
        }
        auto *navigation = new NavStartingHandler(host);
        gateHr = subscriptions.AddHandler(
            webView, &ICoreWebView2::add_NavigationStarting,
            &ICoreWebView2::remove_NavigationStarting, navigation);
        if (SUCCEEDED(gateHr)) {
          navigation = new NavStartingHandler(host);
          gateHr = subscriptions.AddHandler(
              webView, &ICoreWebView2::add_FrameNavigationStarting,
              &ICoreWebView2::remove_FrameNavigationStarting, navigation);
        }
        if (FAILED(gateHr)) {
          webView->Release();
          return gateHr;
        }
        auto *popup = new NewWindowHandler();
        gateHr = subscriptions.AddHandler(
            webView, &ICoreWebView2::add_NewWindowRequested,
            &ICoreWebView2::remove_NewWindowRequested, popup);
        if (FAILED(gateHr)) {
          webView->Release();
          return gateHr;
        }
        // Permisos del navegador (cámara, micrófono, geolocalización,
        // portapapeles, notificaciones...): la cabina no usa ninguno, así que
        // se deniegan todos antes de que WebView2 muestre su aviso. Un registro
        // fallido aborta.
        using PermissionHandler =
            PreviewHandler<ICoreWebView2PermissionRequestedEventHandler,
                           ICoreWebView2 *,
                           ICoreWebView2PermissionRequestedEventArgs *>;
        auto *permission = new PermissionHandler(
            IID_ICoreWebView2PermissionRequestedEventHandler,
            [](ICoreWebView2 *,
               ICoreWebView2PermissionRequestedEventArgs *args) {
              LogWV("[Permission] request denied");
              return webview_policy::DenyPermission(args);
            });
        gateHr = subscriptions.AddHandler(
            webView, &ICoreWebView2::add_PermissionRequested,
            &ICoreWebView2::remove_PermissionRequested, permission);
        if (FAILED(gateHr)) {
          webView->Release();
          return gateHr;
        }
        // Descargas del navegador: se cancelan. Los archivos salen sólo por el
        // puente confinado (doc.save / dialog.saveAs).
        ICoreWebView2_4 *downloadView = nullptr;
        gateHr = webView->QueryInterface(
            IID_ICoreWebView2_4, reinterpret_cast<void **>(&downloadView));
        if (FAILED(gateHr) || !downloadView) {
          webView->Release();
          return FAILED(gateHr) ? gateHr : E_NOINTERFACE;
        }
        using DownloadHandler =
            PreviewHandler<ICoreWebView2DownloadStartingEventHandler,
                           ICoreWebView2 *,
                           ICoreWebView2DownloadStartingEventArgs *>;
        auto *download = new DownloadHandler(
            IID_ICoreWebView2DownloadStartingEventHandler,
            [](ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *args) {
              LogWV("[Download] download cancelled");
              return webview_policy::CancelDownload(args);
            });
        gateHr = subscriptions.AddHandler(
            downloadView, &ICoreWebView2_4::add_DownloadStarting,
            &ICoreWebView2_4::remove_DownloadStarting, download);
        downloadView->Release();
        if (FAILED(gateHr)) {
          webView->Release();
          return gateHr;
        }
        ICoreWebView2_2 *webView2_2 = nullptr;
        const HRESULT domInterfaceHr = webView->QueryInterface(
            IID_ICoreWebView2_2, reinterpret_cast<void **>(&webView2_2));
        if (FAILED(domInterfaceHr) || !webView2_2) {
          webView->Release();
          return FAILED(domInterfaceHr) ? domInterfaceHr : E_NOINTERFACE;
        }
        const std::wstring startUrl =
            L"https://devagents.local/index.html" + host->GetNavQuery();
        const HRESULT startHr = webview_init::Start(
            webView, webView2_2, new NavCompletedHandler(host),
            new ProcessFailedHandler(host), new DOMContentLoadedHandler(host),
            startUrl.c_str(), subscriptions);
        webView2_2->Release();
        webView->Release();
        if (FAILED(startHr))
          return startHr;

#ifndef NDEBUG
        SetTimer(host->GetParentHwnd(), 1002, 2500,
                 [](HWND hwnd, UINT uMsg, UINT_PTR idEvent, DWORD dwTime) {
                   KillTimer(hwnd, idEvent);
                   PostMessageW(hwnd, WM_APP + 42, 0, 0);
                 });
#endif

        return S_OK;
      },
      [&]() {
        ClearMainSubscriptions(host);
        host->SetWebView(nullptr);
        const HRESULT closeHr = controller->Close();
        if (FAILED(closeHr))
          LogWV("[WebView2] abort Close failed hr=" + std::to_string(closeHr));
        host->SetController(nullptr);
      },
      [&](HRESULT hr) { ReportInitializationError(host, hr); });
}

void WebViewHost::DumpDomToCdpFile() {
#ifndef NDEBUG
  LogWV("[DumpDomToCdpFile] m_webView ptr=0x" +
        std::to_string((uintptr_t)m_webView));
  if (m_webView) {
    LogWV("[DumpDomToCdpFile] Executing script on live DOM...");
    HRESULT hrEx = m_webView->ExecuteScript(
        L"(function(){ return JSON.stringify({ title: document.title, "
        L"innerText: document.body.innerText, url: window.location.href, ids: "
        L"Array.from(document.querySelectorAll('[id]')).map(function(e){ "
        L"return e.id; }) }); })()",
        new ExecuteScriptCompletedHandler(nullptr, nullptr));
    LogWV("[DumpDomToCdpFile] ExecuteScript hr=0x" + std::to_string(hrEx));
  }
#endif
}

struct WebViewHost::PreviewState {
  bool alive = true;
  bool captureBusy = false;
  unsigned long epoch = 0;
  std::wstring root;
  std::wstring startUrl;
  long orderId = 0;
  int windowId = 0;
  MessageCallback picked;
};

template <class T> static std::shared_ptr<T> HoldCom(T *value) {
  value->AddRef();
  return std::shared_ptr<T>(value, [](T *p) { p->Release(); });
}

bool WebViewHost::ConfigurePreview(const std::wstring &root,
                                   const std::string &path, long orderId,
                                   int windowId, MessageCallback picked) {
  std::string reason;
  const std::wstring canonicalRoot = preview::CanonicalRoot(root);
  if (canonicalRoot.empty() || orderId <= 0 || windowId <= 0 || !picked ||
      !preview::HtmlPath(path) || !preview::SafeTree(canonicalRoot, reason) ||
      !preview::Resource(canonicalRoot,
                         L"https://preview.local/" + preview::Wide(path))) {
    LogPreview(
        "[Preview] rejected configuration: " +
        (reason.empty() ? "invalid path/order or missing HTML" : reason));
    return false;
  }
  m_preview = std::make_shared<PreviewState>();
  m_preview->root = canonicalRoot;
  m_preview->orderId = orderId;
  m_preview->windowId = windowId;
  m_preview->picked = std::move(picked);
  m_preview->startUrl = L"https://preview.local/";
  static const char hex[] = "0123456789ABCDEF";
  for (unsigned char c : path) {
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9') || c == '/' || c == '-' || c == '_' ||
        c == '.' || c == '~')
      m_preview->startUrl += static_cast<wchar_t>(c);
    else {
      m_preview->startUrl += L'%';
      m_preview->startUrl += hex[c >> 4];
      m_preview->startUrl += hex[c & 15];
    }
  }
  m_onMessage = {}; // never route an untrusted page into the main bridge.
  return true;
}

HRESULT WebViewHost::InitializePreview(ICoreWebView2 *view, bool devTools) {
#ifdef NDEBUG
  devTools = false;
#endif
  if (!view || !m_preview || !s_sharedEnv)
    return E_INVALIDARG;
  const std::weak_ptr<PreviewState> weak = m_preview;
  // Folder mappings bypass WebResourceRequested. Preview resources instead
  // receive a host response containing bytes from the checked open handle.
  ICoreWebView2Settings *settings = nullptr;
  HRESULT hr = view->get_Settings(&settings);
  if (FAILED(hr) || !settings)
    return FAILED(hr) ? hr : E_FAIL;
  hr = preview::ApplySettings(settings, devTools);
  settings->Release();
  if (FAILED(hr))
    return hr;
  EventRegistrationToken token{};
  using Nav = PreviewHandler<ICoreWebView2NavigationStartingEventHandler,
                             ICoreWebView2 *,
                             ICoreWebView2NavigationStartingEventArgs *>;
  auto *navigation = new Nav(
      IID_ICoreWebView2NavigationStartingEventHandler,
      [weak](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) {
        const auto state = weak.lock();
        wchar_t *uri = nullptr;
        const HRESULT result = args ? args->get_Uri(&uri) : E_POINTER;
        std::string path;
        const bool allowed = state && state->alive && SUCCEEDED(result) &&
                             uri && preview::UrlPath(uri, path) &&
                             preview::HtmlPath(path) &&
                             preview::Resource(state->root, uri);
        if (uri)
          CoTaskMemFree(uri);
        if (!allowed) {
          LogPreview("[Preview] navigation rejected");
          return args ? args->put_Cancel(TRUE) : E_POINTER;
        }
        ++state->epoch;
        return S_OK;
      });
  hr = view->add_NavigationStarting(navigation, &token);
  navigation->Release();
  if (FAILED(hr))
    return hr;
  auto *frames = new Nav(
      IID_ICoreWebView2NavigationStartingEventHandler,
      [](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *args) {
        LogPreview("[Preview] iframe navigation rejected");
        return args ? args->put_Cancel(TRUE) : E_POINTER;
      });
  hr = view->add_FrameNavigationStarting(frames, &token);
  frames->Release();
  if (FAILED(hr))
    return hr;
  using Popup = PreviewHandler<ICoreWebView2NewWindowRequestedEventHandler,
                               ICoreWebView2 *,
                               ICoreWebView2NewWindowRequestedEventArgs *>;
  auto *popup = new Popup(
      IID_ICoreWebView2NewWindowRequestedEventHandler,
      [](ICoreWebView2 *, ICoreWebView2NewWindowRequestedEventArgs *args) {
        NewWindowHandler popup;
        return popup.Invoke(nullptr, args);
      });
  hr = view->add_NewWindowRequested(popup, &token);
  popup->Release();
  if (FAILED(hr))
    return hr;
  using Permission =
      PreviewHandler<ICoreWebView2PermissionRequestedEventHandler,
                     ICoreWebView2 *,
                     ICoreWebView2PermissionRequestedEventArgs *>;
  auto *permission = new Permission(
      IID_ICoreWebView2PermissionRequestedEventHandler,
      [](ICoreWebView2 *, ICoreWebView2PermissionRequestedEventArgs *args) {
        LogPreview("[Preview] permission rejected");
        return args ? args->put_State(COREWEBVIEW2_PERMISSION_STATE_DENY)
                    : E_POINTER;
      });
  hr = view->add_PermissionRequested(permission, &token);
  permission->Release();
  if (FAILED(hr))
    return hr;
  using Resource = PreviewHandler<ICoreWebView2WebResourceRequestedEventHandler,
                                  ICoreWebView2 *,
                                  ICoreWebView2WebResourceRequestedEventArgs *>;
  const auto env = HoldCom(s_sharedEnv);
  auto *resource = new Resource(
      IID_ICoreWebView2WebResourceRequestedEventHandler,
      [weak, env](ICoreWebView2 *sender,
                  ICoreWebView2WebResourceRequestedEventArgs *args) {
        const auto state = weak.lock();
        if (!args || !sender)
          return E_POINTER;
        ICoreWebView2WebResourceRequest *request = nullptr;
        wchar_t *uri = nullptr;
        const HRESULT requestHr = args->get_Request(&request);
        const HRESULT uriHr = request ? request->get_Uri(&uri) : E_FAIL;
        wchar_t *method = nullptr;
        const HRESULT methodHr =
            request ? request->get_Method(&method) : E_FAIL;
        const bool head = method && wcscmp(method, L"HEAD") == 0;
        std::vector<unsigned char> bytes;
        const bool allowed = state && state->alive && SUCCEEDED(requestHr) &&
                             SUCCEEDED(uriHr) && SUCCEEDED(methodHr) && uri &&
                             method && (head || wcscmp(method, L"GET") == 0) &&
                             preview::ReadResource(state->root, uri, bytes);
        const std::wstring headers =
            allowed
                ? L"Content-Type: " + std::wstring(preview::ResourceType(uri)) +
                      L"\r\nContent-Length: " + std::to_wstring(bytes.size()) +
                      L"\r\nCache-Control: no-store\r\nX-Content-Type-Options: "
                      L"nosniff\r\n"
                : L"Content-Type: text/plain\r\nCache-Control: no-store\r\n";
        if (uri)
          CoTaskMemFree(uri);
        if (method)
          CoTaskMemFree(method);
        if (request)
          request->Release();
        if (!allowed)
          LogPreview("[Preview] external or unsafe resource rejected");
        IStream *body = nullptr;
        HRESULT block = S_OK;
        if (allowed && !head) {
          block = CreateStreamOnHGlobal(nullptr, TRUE, &body);
          if (SUCCEEDED(block) && !body)
            block = E_FAIL;
          if (SUCCEEDED(block) && !bytes.empty()) {
            ULONG written = 0;
            block = body->Write(bytes.data(), static_cast<ULONG>(bytes.size()),
                                &written);
            if (SUCCEEDED(block) && written != bytes.size())
              block = STG_E_WRITEFAULT;
          }
          if (SUCCEEDED(block)) {
            LARGE_INTEGER zero{};
            block = body->Seek(zero, STREAM_SEEK_SET, nullptr);
          }
        }
        ICoreWebView2WebResourceResponse *response = nullptr;
        if (SUCCEEDED(block))
          block = env->CreateWebResourceResponse(
              body, allowed ? 200 : 403,
              allowed ? L"OK" : L"Preview resource blocked", headers.c_str(),
              &response);
        if (body)
          body->Release();
        if (SUCCEEDED(block) && response) {
          block = args->put_Response(response);
          response->Release();
        } else if (SUCCEEDED(block))
          block = E_FAIL;
        if (FAILED(block)) {
          if (state)
            state->alive = false;
          const HRESULT stop = sender->Stop();
          LogPreview("[Preview] resource block failure hr=" +
                     std::to_string(block) + " stop=" + std::to_string(stop));
        }
        return block;
      });
  hr = view->AddWebResourceRequestedFilter(
      L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
  if (FAILED(hr)) {
    resource->Release();
    return hr;
  }
  hr = view->add_WebResourceRequested(resource, &token);
  resource->Release();
  if (FAILED(hr))
    return hr;
  ICoreWebView2_4 *downloadView = nullptr;
  hr = view->QueryInterface(IID_ICoreWebView2_4,
                            reinterpret_cast<void **>(&downloadView));
  if (FAILED(hr) || !downloadView)
    return FAILED(hr) ? hr : E_NOINTERFACE;
  using Download =
      PreviewHandler<ICoreWebView2DownloadStartingEventHandler, ICoreWebView2 *,
                     ICoreWebView2DownloadStartingEventArgs *>;
  auto *download = new Download(
      IID_ICoreWebView2DownloadStartingEventHandler,
      [](ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *args) {
        LogPreview("[Preview] download rejected");
        return args ? args->put_Cancel(TRUE) : E_POINTER;
      });
  hr = downloadView->add_DownloadStarting(download, &token);
  download->Release();
  downloadView->Release();
  if (FAILED(hr))
    return hr;
  using Message = PreviewHandler<ICoreWebView2WebMessageReceivedEventHandler,
                                 ICoreWebView2 *,
                                 ICoreWebView2WebMessageReceivedEventArgs *>;
  auto *message = new Message(
      IID_ICoreWebView2WebMessageReceivedEventHandler,
      [weak](ICoreWebView2 *sender,
             ICoreWebView2WebMessageReceivedEventArgs *args) {
        const auto state = weak.lock();
        if (!state || !state->alive || !sender || !args)
          return S_OK;
        wchar_t *wide = nullptr, *source = nullptr, *current = nullptr;
        const HRESULT messageHr = args->get_WebMessageAsJson(&wide);
        const HRESULT sourceHr = args->get_Source(&source);
        const HRESULT currentHr = sender->get_Source(&current);
        std::string raw;
        if (SUCCEEDED(messageHr) && wide &&
            wcsnlen_s(wide, preview::MessageLimit + 1) <= preview::MessageLimit)
          raw = preview::Narrow(wide);
        preview::Value element;
        std::string reason;
        const bool valid = preview::Picked(raw, element, reason) &&
                           SUCCEEDED(sourceHr) && SUCCEEDED(currentHr) &&
                           source && current &&
                           preview::Provenance(source, current, element) &&
                           preview::Resource(state->root, source);
        const std::wstring origin = source ? source : L"";
        if (wide)
          CoTaskMemFree(wide);
        if (source)
          CoTaskMemFree(source);
        if (current)
          CoTaskMemFree(current);
        if (!valid || state->captureBusy) {
          LogPreview("[Preview] message ignored: " +
                     (reason.empty() ? "provenance_or_busy" : reason));
          return S_OK;
        }
        IStream *stream = nullptr;
        const HRESULT streamHr = CreateStreamOnHGlobal(nullptr, TRUE, &stream);
        if (FAILED(streamHr) || !stream) {
          LogPreview("[Preview] capture stream failed hr=" +
                     std::to_string(streamHr));
          return S_OK;
        }
        const auto heldStream = HoldCom(stream);
        stream->Release();
        const auto heldView = HoldCom(sender);
        const unsigned long epoch = state->epoch;
        state->captureBusy = true;
        std::ostringstream viewport;
        viewport.imbue(std::locale::classic());
        const auto &v = element.object.at("viewport").object;
        viewport << "{\"width\":" << v.at("width").number
                 << ",\"height\":" << v.at("height").number
                 << ",\"devicePixelRatio\":" << v.at("devicePixelRatio").number
                 << "}";
        const std::string viewportJson = viewport.str();
        using Capture =
            PreviewHandler<ICoreWebView2CapturePreviewCompletedHandler,
                           HRESULT>;
        auto *capture = new Capture(
            IID_ICoreWebView2CapturePreviewCompletedHandler,
            [weak, heldStream, heldView, raw, viewportJson, origin,
             epoch](HRESULT result) {
              const auto captured = weak.lock();
              if (!captured)
                return S_OK;
              captured->captureBusy = false;
              if (!captured->alive || captured->epoch != epoch)
                return S_OK;
              wchar_t *now = nullptr;
              const HRESULT nowHr = heldView->get_Source(&now);
              const bool same = SUCCEEDED(nowHr) && now && origin == now;
              if (now)
                CoTaskMemFree(now);
              STATSTG stat{};
              if (FAILED(result) || !same ||
                  FAILED(heldStream->Stat(&stat, STATFLAG_NONAME)) ||
                  stat.cbSize.QuadPart < 24 ||
                  stat.cbSize.QuadPart > preview::CaptureLimit) {
                LogPreview("[Preview] capture failed or exceeded bound");
                return S_OK;
              }
              std::vector<unsigned char> bytes(
                  static_cast<size_t>(stat.cbSize.QuadPart));
              LARGE_INTEGER zero{};
              ULONG read = 0;
              if (FAILED(heldStream->Seek(zero, STREAM_SEEK_SET, nullptr)) ||
                  FAILED(heldStream->Read(
                      bytes.data(), static_cast<ULONG>(bytes.size()), &read)) ||
                  read != bytes.size() ||
                  memcmp(bytes.data(), "\x89PNG\r\n\x1a\n", 8) != 0) {
                LogPreview("[Preview] invalid PNG capture");
                return S_OK;
              }
              const std::string encoded =
                  preview::Base64(bytes.data(), bytes.size());
              if (encoded.empty()) {
                LogPreview("[Preview] empty capture");
                return S_OK;
              }
              captured->picked(preview::Wide(
                  "{\"push\":\"preview.elementPicked\",\"payload\":{\"order_"
                  "id\":" +
                  std::to_string(captured->orderId) +
                  ",\"window_id\":" + std::to_string(captured->windowId) +
                  ",\"element\":" + raw + ",\"viewport\":" + viewportJson +
                  ",\"capture_base64\":\"" + encoded + "\"}}"));
              return S_OK;
            });
        const HRESULT captureHr = sender->CapturePreview(
            COREWEBVIEW2_CAPTURE_PREVIEW_IMAGE_FORMAT_PNG, heldStream.get(),
            capture);
        capture->Release();
        if (FAILED(captureHr)) {
          state->captureBusy = false;
          LogPreview("[Preview] CapturePreview failed hr=" +
                     std::to_string(captureHr));
        }
        return S_OK;
      });
  hr = view->add_WebMessageReceived(message, &token);
  message->Release();
  if (FAILED(hr))
    return hr;
  using Script = PreviewHandler<
      ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler, HRESULT,
      LPCWSTR>;
  const auto heldView = HoldCom(view);
  auto *script = new Script(
      IID_ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler,
      [weak, heldView](HRESULT result, LPCWSTR) {
        const auto state = weak.lock();
        if (!state || !state->alive)
          return S_OK;
        if (FAILED(result)) {
          LogPreview("[Preview] selector injection failed hr=" +
                     std::to_string(result));
          state->alive = false;
          return result;
        }
        const HRESULT nav = heldView->Navigate(state->startUrl.c_str());
        if (FAILED(nav))
          LogPreview("[Preview] initial navigation failed hr=" +
                     std::to_string(nav));
        return nav;
      });
  hr = view->AddScriptToExecuteOnDocumentCreated(PreviewSelectorScript(),
                                                 script);
  script->Release();
  return hr;
}

WebViewHost::WebViewHost() {}

// -- Recuperacion (22-09) ---------------------------------------------------
// El temporizador de Win32 no lleva contexto: se resuelve el WebViewHost por
// el HWND padre (E5.21 — con varias ventanas un puntero global unico enviaba
// la recuperacion a la ventana equivocada).
// El mapa se pierde a proposito: los WebViewHost pueden morir despues de que
// se destruyan los estaticos del proceso, y un mapa ya destruido seria UB.
static std::unordered_map<HWND, WebViewHost *> &Hosts() {
  static auto *m = new std::unordered_map<HWND, WebViewHost *>();
  return *m;
}
static const UINT_PTR kRecoveryTimerId = 1003;

static void CALLBACK RecoveryTimerProc(HWND hwnd, UINT, UINT_PTR id, DWORD) {
  KillTimer(hwnd, id);
  auto it = Hosts().find(hwnd);
  if (it != Hosts().end() && it->second)
    it->second->RunRecovery();
}

void WebViewHost::ScheduleRecovery(bool recreate) {
  Hosts()[m_parentHwnd] = this;
  m_recoveryRecreate = m_recoveryRecreate || recreate;
  // 1 s para recrear; para recargar, 5 -> 10 -> 20 -> 30 s y se queda en 30.
  // Sin tope de intentos: un reintento cada 30 s no cuesta nada, y rendirse
  // es exactamente la pantalla blanca permanente que se esta cerrando.
  const int shift = m_recoveryAttempts < 3 ? m_recoveryAttempts : 3;
  UINT delay = m_recoveryRecreate ? 1000u : (5000u << shift);
  if (delay > 30000u)
    delay = 30000u;
  m_recoveryAttempts++;
  LogWV("[Recovery] intento " + std::to_string(m_recoveryAttempts) + " en " +
        std::to_string(delay) + " ms" +
        (m_recoveryRecreate ? " (recrear)" : ""));
  SetTimer(m_parentHwnd, kRecoveryTimerId, delay, RecoveryTimerProc);
}

void WebViewHost::RunRecovery() {
  const bool recreate = m_recoveryRecreate || !m_webView;
  m_recoveryRecreate = false;
  if (!recreate) {
    LogWV("[Recovery] recargando");
    m_webView->Reload();
    return;
  }
  LogWV("[Recovery] recreando entorno y controlador");
  ClearMainSubscriptions(this);
  if (m_controller) {
    m_controller->Close();
    m_controller->Release();
    m_controller = nullptr;
  }
  if (m_webView) {
    m_webView->Release();
    m_webView = nullptr;
  }
  m_crashReloads = 0;
  if (!Initialize(m_parentHwnd, m_initUserDataDir, m_initBundleDir,
                  m_initDevTools, m_initExtraArgs))
    ScheduleRecovery(true);
}

// máx. 3 recargas por ventana de 60 s. Si el renderer muere por una
// causa persistente (perfil corrupto, falta de memoria crónica), el bucle
// crash→reload→crash no debe esconder el problema para siempre: queda en
// blanco pero el log cuenta cada intento.
bool WebViewHost::NoteCrashForReload() {
  const auto now = std::chrono::steady_clock::now();
  if (m_crashReloads == 0 || now - m_firstCrash > std::chrono::seconds(60)) {
    m_firstCrash = now;
    m_crashReloads = 0;
  }
  if (m_crashReloads >= 3)
    return false;
  m_crashReloads++;
  return true;
}

WebViewHost::~WebViewHost() {
  ClearMainSubscriptions(this);
  if (m_preview) {
    m_preview->alive = false;
    m_preview.reset();
  }
  if (m_parentHwnd) {
    auto it = Hosts().find(m_parentHwnd);
    if (it != Hosts().end() && it->second == this)
      Hosts().erase(it);
  }
  if (m_controller) {
    m_controller->Close();
    m_controller->Release();
    m_controller = nullptr;
  }
  if (m_webView) {
    m_webView->Release();
    m_webView = nullptr;
  }
}

class EnvOptions : public ICoreWebView2EnvironmentOptions {
public:
  std::wstring additionalArgs;
  // El cargador de WebView2 EXIGE una version compatible legible: si el getter
  // devuelve NULL no puede comparar contra el runtime instalado y aborta la
  // creacion del entorno con E_INVALIDARG. El sintoma era una ventana en negro
  // cada vez que se pasaban argumentos de navegador (es decir, siempre que se
  // arrancaba con /devtools).
  std::wstring language;
  // Mismo valor que CORE_WEBVIEW_TARGET_PRODUCT_VERSION del SDK vendorizado
  // (shell/host/sdk/build/native/include/WebView2EnvironmentOptions.h). No se
  // incluye esa cabecera porque arrastra WRL, que este toolchain no tiene.
  std::wstring targetVersion = L"131.0.2903.40";
  ULONG ref = 1;

  EnvOptions(const std::wstring &args) : additionalArgs(args) {}

  // Las cadenas de salida de COM las libera el llamante con CoTaskMemFree, asi
  // que hay que copiarlas al asignador de tareas y no devolver punteros al
  // std::wstring de este objeto.
  static HRESULT CopyOut(const std::wstring &src, LPWSTR *value) {
    if (!value)
      return E_POINTER;
    size_t bytes = (src.size() + 1) * sizeof(wchar_t);
    *value = static_cast<LPWSTR>(CoTaskMemAlloc(bytes));
    if (!*value)
      return E_OUTOFMEMORY;
    wcscpy_s(*value, src.size() + 1, src.c_str());
    return S_OK;
  }

  virtual HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid,
                                                   void **ppv) override {
    if (!ppv)
      return E_POINTER;
    if (riid == IID_IUnknown || riid == IID_ICoreWebView2EnvironmentOptions) {
      *ppv = static_cast<ICoreWebView2EnvironmentOptions *>(this);
      AddRef();
      return S_OK;
    }
    *ppv = nullptr;
    return E_NOINTERFACE;
  }

  virtual ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&ref);
  }
  virtual ULONG STDMETHODCALLTYPE Release() override {
    ULONG c = InterlockedDecrement(&ref);
    if (c == 0)
      delete this;
    return c;
  }

  virtual HRESULT STDMETHODCALLTYPE
  get_AdditionalBrowserArguments(LPWSTR *value) override {
    if (!value)
      return E_POINTER;
    return CopyOut(additionalArgs, value);
  }

  virtual HRESULT STDMETHODCALLTYPE
  put_AdditionalBrowserArguments(LPCWSTR value) override {
    if (value)
      additionalArgs = value;
    else
      additionalArgs.clear();
    return S_OK;
  }
  virtual HRESULT STDMETHODCALLTYPE get_Language(LPWSTR *value) override {
    return CopyOut(language, value);
  }
  virtual HRESULT STDMETHODCALLTYPE put_Language(LPCWSTR value) override {
    language = value ? value : L"";
    return S_OK;
  }
  virtual HRESULT STDMETHODCALLTYPE
  get_TargetCompatibleBrowserVersion(LPWSTR *value) override {
    return CopyOut(targetVersion, value);
  }
  virtual HRESULT STDMETHODCALLTYPE
  put_TargetCompatibleBrowserVersion(LPCWSTR value) override {
    if (value && *value)
      targetVersion = value;
    return S_OK;
  }
  virtual HRESULT STDMETHODCALLTYPE
  get_AllowSingleSignOnUsingOSPrimaryAccount(BOOL *allow) override {
    if (allow)
      *allow = FALSE;
    return S_OK;
  }
  virtual HRESULT STDMETHODCALLTYPE
  put_AllowSingleSignOnUsingOSPrimaryAccount(BOOL allow) override {
    return S_OK;
  }
};

bool WebViewHost::Initialize(HWND hWnd, const std::wstring &userDataDir,
                             const std::wstring &bundleDir, bool enableDevTools,
                             const std::wstring &extraCmdArgs) {
#ifdef NDEBUG
  enableDevTools = false;
  // Release cannot acquire CDP through inherited env or forwarded CLI flags.
  if (!SetEnvironmentVariableW(L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS",
                               nullptr)) {
    LogWV("[Initialize] failed to clear release browser arguments");
    return false;
  }
#endif
  m_parentHwnd = hWnd;
  // Se guardan para poder recrear el WebView si muere su navegador.
  m_initUserDataDir = userDataDir;
  m_initBundleDir = bundleDir;
  m_initDevTools = enableDevTools;
#ifndef NDEBUG
  m_initExtraArgs = extraCmdArgs;
#else
  m_initExtraArgs.clear();
#endif
  Hosts()[hWnd] = this;

  std::wstring targetUserDataDir = userDataDir;
  const char *devToolsEnv = nullptr;
#ifndef NDEBUG
  devToolsEnv = std::getenv("DEVAGENTS_DEVTOOLS_PORT");
  if (!devToolsEnv || std::string(devToolsEnv) == "") {
    devToolsEnv = std::getenv("BEATS_DEVTOOLS_PORT");
  }
#endif
  if (targetUserDataDir.empty()) {
    if (devToolsEnv && std::string(devToolsEnv) != "") {
      targetUserDataDir = L"C:\\tmp\\beats_webview_dev_userdata";
    } else {
      wchar_t appDataPath[MAX_PATH];
      if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0,
                                     appDataPath))) {
        targetUserDataDir =
            std::wstring(appDataPath) + L"\\DevAgents-Angel\\WebView2Data";
      } else {
        targetUserDataDir = L"C:\\tmp\\beats_webview_userdata";
      }
    }
  }

  ICoreWebView2EnvironmentOptions *options = nullptr;
  std::wstring combinedArgs;
#ifndef NDEBUG
  combinedArgs = extraCmdArgs;
  if (devToolsEnv && std::string(devToolsEnv) != "") {
    if (!combinedArgs.empty())
      combinedArgs += L" ";
    // E3.39-D: NUNCA `--remote-allow-origins=*`. Chromium rechaza los
    // WebSocket CDP que traen cabecera Origin salvo que el flag la autorice;
    // con `*` cualquier página web (o proceso local) podía tomar el control
    // del WebView — verificado con Origin https://evil.example.com ejecutando
    // Runtime.evaluate. Los drivers propios (Node/undici) no envían Origin y
    // siguen conectando. El puerto además solo abre en builds de depuración y
    // queda anclado a loopback por Chromium.
    combinedArgs += L"--remote-debugging-port=" + Utf8ToWide(devToolsEnv);
  }
#endif
  if (!combinedArgs.empty()) {
    // Arguments belong to this environment; a process-wide override would
    // leak UI CDP/flags into the separate browser profile.
    options = new EnvOptions(combinedArgs);
  }

  // E5.21: todas las ventanas comparten entorno. Si ya existe con la misma
  // clave (perfil + argumentos), el controlador se crea directo sobre él; si
  // está en vuelo, esta ventana se encola hasta que complete.
  const std::wstring envKey = targetUserDataDir + L"|" + combinedArgs;
  if (s_sharedEnv && envKey == s_envKey) {
    CreateControllerOnEnv(s_sharedEnv, this, bundleDir, enableDevTools);
    return true;
  }
  if (s_envInFlight && envKey == s_envKey) {
    s_envPending.push_back(this);
    return true;
  }

  s_envInFlight = true;
  s_envKey = envKey;
  HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
      nullptr, targetUserDataDir.c_str(), options,
      new EnvCompletedHandler(this, bundleDir, enableDevTools));
  if (FAILED(hr))
    s_envInFlight = false;

  LogWV("[Initialize] CreateCoreWebView2EnvironmentWithOptions hr=0x" +
        std::to_string(hr));

  return SUCCEEDED(hr);
}

void WebViewHost::Resize(int width, int height) {
  if (m_controller) {
    RECT bounds = {0, 0, std::max(0, width), std::max(0, height)};
    const auto hr = m_controller->put_Bounds(bounds);
    if (FAILED(hr))
      LogWV("[Layout] resize failed hr=" + std::to_string(hr));
  }
}
void WebViewHost::NotifyMoved() {
  if (m_controller)
    m_controller->NotifyParentWindowPositionChanged();
}
bool WebViewHost::GetBounds(RECT &bounds) const {
  return m_controller && SUCCEEDED(m_controller->get_Bounds(&bounds));
}

bool WebViewHost::PostMessageJson(const std::wstring &jsonMessage) {
  if (IsPreview())
    return false;
  if (m_webView) {
    HRESULT hr = m_webView->PostWebMessageAsJson(jsonMessage.c_str());
    return SUCCEEDED(hr);
  }
  return false;
}

} // namespace beats

#endif // BEATS_WEBVIEW_INITIALIZATION_ONLY
