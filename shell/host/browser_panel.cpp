#include "browser_panel.hpp"
#include "WebView2.h"
#include "browser_agent_script.hpp"
#include "browser_agent_tools.hpp"
#include "browser_policy.hpp"
#include "preview_policy.hpp"
#include "themed_dialog.hpp"
#include "webview_policy.hpp"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <functional>
#include <map>
#include <vector>

namespace beats {
namespace {
template <class I, class... A> class Handler final : public I {
  ULONG refs = 1;
  GUID iid;
  std::function<HRESULT(A...)> fn;

public:
  Handler(REFIID id, std::function<HRESULT(A...)> f)
      : iid(id), fn(std::move(f)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **out) override {
    if (!out)
      return E_POINTER;
    *out = nullptr;
    if (id != IID_IUnknown && id != iid)
      return E_NOINTERFACE;
    *out = static_cast<I *>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&refs);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    auto n = InterlockedDecrement(&refs);
    if (!n)
      delete this;
    return n;
  }
  HRESULT STDMETHODCALLTYPE Invoke(A... args) override { return fn(args...); }
};
template <class I, class... A, class F>
HRESULT Subscribe(HRESULT (STDMETHODCALLTYPE ICoreWebView2::*method)(
                      I *, EventRegistrationToken *),
                  ICoreWebView2 *view, REFIID iid, F fn) {
  auto *handler = new Handler<I, A...>(iid, fn);
  EventRegistrationToken token{};
  const HRESULT hr = (view->*method)(handler, &token);
  handler->Release();
  return hr;
}
std::wstring Quote(const std::wstring &s) {
  std::wstring out = L"\"";
  for (auto c : s) {
    if (c == L'"' || c == L'\\') {
      out += L'\\';
      out += c;
    } else if (c == L'\n')
      out += L"\\n";
    else if (c == L'\r')
      out += L"\\r";
    else if (c == L'\t')
      out += L"\\t";
    else if (c >= 0x20)
      out += c;
  }
  return out + L"\"";
}
// Spanish reason for a failed main-frame load; the code stays available.
std::wstring LoadError(COREWEBVIEW2_WEB_ERROR_STATUS code) {
  switch (code) {
  case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_COMMON_NAME_IS_INCORRECT:
  case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_EXPIRED:
  case COREWEBVIEW2_WEB_ERROR_STATUS_CLIENT_CERTIFICATE_CONTAINS_ERRORS:
  case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_REVOKED:
  case COREWEBVIEW2_WEB_ERROR_STATUS_CERTIFICATE_IS_INVALID:
    return L"El certificado del sitio no es válido.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_SERVER_UNREACHABLE:
  case COREWEBVIEW2_WEB_ERROR_STATUS_CANNOT_CONNECT:
    return L"No se pudo conectar con el servidor.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_TIMEOUT:
    return L"El servidor tardó demasiado en responder.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_ERROR_HTTP_INVALID_SERVER_RESPONSE:
    return L"El servidor dio una respuesta no válida.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_ABORTED:
    return L"La conexión se interrumpió o la bloqueó la política del panel.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_CONNECTION_RESET:
    return L"El servidor cerró la conexión.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_DISCONNECTED:
    return L"No hay conexión de red.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_HOST_NAME_NOT_RESOLVED:
    return L"No se encontró el sitio: el nombre no se resuelve.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_REDIRECT_FAILED:
    return L"La redirección del servidor falló.";
  case COREWEBVIEW2_WEB_ERROR_STATUS_VALID_AUTHENTICATION_CREDENTIALS_REQUIRED:
  case COREWEBVIEW2_WEB_ERROR_STATUS_VALID_PROXY_AUTHENTICATION_REQUIRED:
    return L"El sitio pide autenticación, que este panel no admite.";
  default:
    return L"No se pudo cargar la página (código " +
           std::to_wstring(static_cast<int>(code)) + L").";
  }
}
// Reason for the last main-document failure that Chromium reported; the raw
// `net::ERR_*` token travels with it as the diagnostic. Unknown tokens fall
// back to the WebView2 status code, which is often UNKNOWN for network errors.
std::wstring NetFailure(const std::string &text, std::wstring fallback) {
  const struct {
    const char *needle;
    const wchar_t *reason;
  } known[] = {
      {"ERR_CONNECTION_REFUSED",
       L"El servidor rechazó la conexión. ¿Está en marcha la app en ese "
       L"puerto?"},
      {"ERR_CONNECTION_TIMED_OUT",
       L"El servidor tardó demasiado en responder."},
      {"ERR_TIMED_OUT", L"El servidor tardó demasiado en responder."},
      {"ERR_NAME_NOT_RESOLVED",
       L"No se encontró el sitio: el nombre no se resuelve."},
      {"ERR_INTERNET_DISCONNECTED", L"No hay conexión de red."},
      {"ERR_NETWORK_CHANGED", L"La red cambió durante la carga."},
      {"ERR_CONNECTION_RESET", L"El servidor cerró la conexión."},
      {"ERR_CONNECTION_CLOSED", L"El servidor cerró la conexión."},
      {"ERR_EMPTY_RESPONSE", L"El servidor cerró la conexión sin responder."},
      {"ERR_CERT_",
       L"No se pudo establecer una conexión segura (certificado)."},
      {"ERR_SSL_", L"No se pudo establecer una conexión segura (TLS)."},
      {"ERR_BLOCKED_BY_CLIENT", L"La política del panel bloqueó la solicitud."},
      {"ERR_TOO_MANY_REDIRECTS", L"Demasiadas redirecciones."},
      {"ERR_ADDRESS_UNREACHABLE", L"La dirección no es alcanzable."}};
  for (const auto &entry : known)
    if (text.find(entry.needle) != std::string::npos)
      return entry.reason;
  return fallback;
}
// Keep SSO off and use no inherited debug/no-sandbox flags.
class Options final : public ICoreWebView2EnvironmentOptions {
  ULONG refs = 1;
  std::wstring args;
  static HRESULT Copy(const std::wstring &s, LPWSTR *out) {
    if (!out)
      return E_POINTER;
    *out =
        static_cast<LPWSTR>(CoTaskMemAlloc((s.size() + 1) * sizeof(wchar_t)));
    if (!*out)
      return E_OUTOFMEMORY;
    wcscpy_s(*out, s.size() + 1, s.c_str());
    return S_OK;
  }

public:
  explicit Options(std::wstring a) : args(std::move(a)) {}
  HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void **out) override {
    if (!out)
      return E_POINTER;
    *out = nullptr;
    if (id != IID_IUnknown && id != IID_ICoreWebView2EnvironmentOptions)
      return E_NOINTERFACE;
    *out = static_cast<ICoreWebView2EnvironmentOptions *>(this);
    AddRef();
    return S_OK;
  }
  ULONG STDMETHODCALLTYPE AddRef() override {
    return InterlockedIncrement(&refs);
  }
  ULONG STDMETHODCALLTYPE Release() override {
    auto n = InterlockedDecrement(&refs);
    if (!n)
      delete this;
    return n;
  }
  HRESULT STDMETHODCALLTYPE get_AdditionalBrowserArguments(LPWSTR *v) override {
    return Copy(args, v);
  }
  HRESULT STDMETHODCALLTYPE put_AdditionalBrowserArguments(LPCWSTR v) override {
    args = v ? v : L"";
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE get_Language(LPWSTR *v) override {
    return Copy(L"", v);
  }
  HRESULT STDMETHODCALLTYPE put_Language(LPCWSTR) override { return S_OK; }
  HRESULT STDMETHODCALLTYPE
  get_TargetCompatibleBrowserVersion(LPWSTR *v) override {
    return Copy(L"131.0.2903.40", v);
  }
  HRESULT STDMETHODCALLTYPE
  put_TargetCompatibleBrowserVersion(LPCWSTR) override {
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE
  get_AllowSingleSignOnUsingOSPrimaryAccount(BOOL *v) override {
    if (!v)
      return E_POINTER;
    *v = FALSE;
    return S_OK;
  }
  HRESULT STDMETHODCALLTYPE
  put_AllowSingleSignOnUsingOSPrimaryAccount(BOOL v) override {
    return v ? E_ACCESSDENIED : S_OK;
  }
};
constexpr int Tabs = 101, Add = 102, Remove = 103, IdBack = 104,
              IdForward = 105, IdReload = 106, Address = 107, Go = 108,
              HideControl = 109, Status = 110, Register = 111;
constexpr const wchar_t *GuardUrl = L"https://browser-guard.local/check.html";
} // namespace

struct BrowserPanel::Impl : std::enable_shared_from_this<BrowserPanel::Impl> {
  // WH_*_LL executes on the installing STA even when the destination HWND is
  // owned by the OOP renderer. One bounded registry per message-pump thread
  // avoids installing duplicate desktop hooks for each browser window.
  struct PhysicalHooks {
    HHOOK mouse = nullptr, keyboard = nullptr;
    std::array<Impl *, 32> panels{};
  };
  static PhysicalHooks &ThreadHooks() noexcept {
    static thread_local PhysicalHooks hooks;
    return hooks;
  }
  bool physicalRegistered = false, physicalTakePending = false;
  static constexpr UINT PhysicalControlMessage = WM_APP + 417;
  struct Tab {
    unsigned id = 0;
    std::string agentId;
    // Petición browser_navigate del agente que espera a que esta pestaña
    // termine de navegar (vacío si no hay ninguna).
    std::string agentNav;
    // Contexto del mundo aislado del agente en el documento actual (0: sin
    // crear). Se olvida en cada navegación: tras un cambio de proceso un id
    // viejo podría señalar el mundo de la página.
    int agentWorld = 0;
    // T6: mundo aislado propio de browser_debug_js (nunca el del registro de
    // referencias del agente). Se olvida en cada navegación, como agentWorld.
    int debugWorld = 0;
    // T6: registros acotados de consola y de red de esta pestaña
    // (browser_console, browser_network) y si Runtime.enable respondió.
    browser_agent::Ring<browser_agent::ConsoleEntry> console;
    browser_agent::Ring<browser_agent::NetworkEntry> network;
    bool consoleReady = false;
    ICoreWebView2Controller *controller = nullptr;
    ICoreWebView2 *view = nullptr;
    bool ready = false, closed = false, loading = false;
    bool canBack = false, canForward = false, hasError = false, blocked = false;
    int errorCode = 0;
    std::wstring pending = L"about:blank", title = L"Nueva pestaña", url, error,
                 errorDetail, netError, blockedUrl, blockedReason;
    ~Tab() {
      if (controller) {
        controller->Close();
        controller->Release();
      }
      if (view)
        view->Release();
    }
  };
  // A destination the trusted UI is being asked about. The page can neither
  // see nor answer it: only the bridge handler can resolve it, by id.
  // Every navigation waiting on the same exact origin shares one request and
  // one dialog; the single answer applies to all of them, never to another
  // origin.
  struct Waiter {
    unsigned tab = 0; // 0: a new tab that does not exist yet
    std::function<void()> resume;
  };
  struct Approval {
    std::string id;
    std::wstring origin;
    const char *source = "address";
    ULONGLONG at = 0;
    std::vector<Waiter> waiters;
  };
  enum class Admit { Go, Asked, Refused };
  static constexpr ULONGLONG ApprovalTimeoutMs = 120000;
  static constexpr ULONGLONG DeniedQuietMs = 30000;
  static constexpr size_t MaxApprovals = 3;
  static constexpr size_t MaxWaiters = 8;
  HWND parent = nullptr, hwnd = nullptr;
  bool alive = true, full = false, initializing = false, open = false;
  ICoreWebView2Environment *env = nullptr;
  browser::Policy policy;
  std::wstring dataRoot, fixtureRoot, ledger;
  std::vector<std::shared_ptr<Tab>> tabs;
  size_t active = 0;
  unsigned nextTab = 1;
  EventSink sink;
  ControlSink controlSink;
  std::string sessionId, initialTabId, controlState = "session_closed";
  uint64_t controlEpoch = 0;
  struct AgentPending {
    AgentCompletion done;
    uint64_t epoch = 0;
    ULONGLONG deadline = 0;
    std::vector<unsigned> tabs;
    std::map<unsigned, std::wstring> titles;
    unsigned active = 0;
    // Navegación del agente: pestaña que carga y plazo de ESA carga. El plazo
    // de la petición (`deadline`) incluye además la espera de la aprobación
    // humana del origen; mientras el usuario decide, la carga no cuenta.
    unsigned navTab = 0;
    ULONGLONG loadMs = 0, loadDeadline = 0;
    // Atrás/adelante dentro del mismo documento no emite NavigationCompleted:
    // se da por hecha cuando la pestaña lleva un momento sin cargar.
    bool history = false;
    ULONGLONG started = 0;
    // browser_tabs create/close/select: el resultado es la lista de pestañas
    // más la pestaña creada o cerrada.
    bool listAfter = false;
    std::string extraTab;
  };
  std::map<std::string, AgentPending> agentPending;
  struct InputHook {
    std::weak_ptr<Impl> owner;
    WNDPROC previous = nullptr;
  };
  std::map<HWND, InputHook *> inputHooks;
  std::vector<Approval> approvals;
  std::map<std::wstring, ULONGLONG> denied;
  std::wstring status = L"Inicializando navegador";
  bool statusError = false;
  std::string reason;
  ~Impl() {
    UnregisterPhysicalInput();
    FinishAllAgent("session_closed");
    alive = false;
    for (const auto &entry : inputHooks) {
      if (IsWindow(entry.first)) {
        SetWindowLongPtrW(entry.first, GWLP_WNDPROC,
                          reinterpret_cast<LONG_PTR>(entry.second->previous));
        RemovePropW(entry.first, L"DevAgentsBrowserInput");
      }
      delete entry.second;
    }
    inputHooks.clear();
    tabs.clear();
    if (env)
      env->Release();
    if (hwnd)
      DestroyWindow(hwnd);
  }
  static bool Blank(const std::wstring &url) {
    return url.empty() || url == L"about:blank";
  }
  static std::string JsonText(const std::wstring &s, size_t cap = 2048) {
    std::string out = "\"";
    char unit[8];
    size_t count = 0;
    for (const wchar_t c : s) {
      if (++count > cap)
        break;
      if (c == L'"' || c == L'\\') {
        out += '\\';
        out += static_cast<char>(c);
      } else if (c >= 0x20 && c < 0x7f)
        out += static_cast<char>(c);
      else {
        std::snprintf(unit, sizeof(unit), "\\u%04x",
                      static_cast<unsigned>(c) & 0xffffu);
        out += unit;
      }
    }
    return out + "\"";
  }
  static const char *Flag(bool v) { return v ? "true" : "false"; }
  static std::wstring CleanTitle(const std::wstring &title) {
    std::wstring clean;
    for (size_t i = 0; i < title.size(); ++i) {
      const wchar_t c = title[i];
      if (clean.size() == 160)
        break;
      if (c >= 0xd800 && c <= 0xdbff) {
        if (i + 1 < title.size() && title[i + 1] >= 0xdc00 &&
            title[i + 1] <= 0xdfff && clean.size() <= 158) {
          clean += c;
          clean += title[++i];
        }
        continue;
      }
      if (c >= 0xdc00 && c <= 0xdfff)
        continue;
      if (c >= 0x20 && !(c >= 0x7f && c <= 0x9f) && c != 0x061c &&
          c != 0x200e && c != 0x200f && !(c >= 0x202a && c <= 0x202e) &&
          !(c >= 0x2066 && c <= 0x2069))
        clean += c;
    }
    return clean;
  }
  static std::string AgentError(const std::string &id,
                                const std::string &code) {
    return "{\"request_id\":" + JsonText(preview::Wide(id), 256) +
           ",\"ok\":false,\"error\":{\"code\":" +
           JsonText(preview::Wide(code), 64) +
           ",\"message\":" + JsonText(preview::Wide(code), 64) +
           ",\"retryable\":false,\"effect_status\":\"not_started\"}}";
  }
  void FinishAgent(const std::string &id, const std::string &code) {
    const auto it = agentPending.find(id);
    if (it == agentPending.end())
      return;
    auto done = std::move(it->second.done);
    agentPending.erase(it);
    done(AgentError(id, code));
  }
  void FinishAllAgent(const std::string &code, unsigned tab = 0) {
    std::vector<std::string> ids;
    // `active` es la pestaña sobre la que opera una petición de una sola
    // pestaña (navegar, leer); `tabs`, las que recorre un listado.
    for (const auto &entry : agentPending)
      if (!tab || entry.second.active == tab ||
          std::find(entry.second.tabs.begin(), entry.second.tabs.end(), tab) !=
              entry.second.tabs.end())
        ids.push_back(entry.first);
    for (const auto &id : ids)
      FinishAgent(id, code);
  }
  void HumanControl() {
    if (physicalTakePending) {
      FlushPhysicalControl();
      return;
    }
    if (sessionId.empty() || !open || controlState == "user_control")
      return;
    controlState = "user_control";
    ++controlEpoch;
    FinishAllAgent("user_control");
    // Notify before dispatching the native input to Chromium.
    if (controlSink)
      controlSink("take", Active() ? Active()->agentId : "");
    Publish();
  }
  // Acción humana desde la barra de la cabina sobre la pestaña activa: corta
  // lo que el agente tuviera a medias en ella, sin quitarle el control.
  void HumanStep() {
    if (const auto t = Active()) {
      FinishAllAgent("busy", t->id);
      t->agentNav.clear();
    }
  }
  void QueuePhysicalControl() noexcept {
    if (!alive || !open || sessionId.empty() ||
        controlState != "agent_control" || physicalTakePending)
      return;
    // No allocation, COM, disk, tool completion or user callback in an LL
    // hook. Revoke the local epoch before the input reaches Chromium; drain
    // terminals and notify the motor on the next normal STA message.
    physicalTakePending = true;
    ++controlEpoch;
    // If posting fails the pending flag still blocks execution; the existing
    // panel timer also drains it, or teardown supplies session_closed.
    PostMessageW(hwnd, PhysicalControlMessage, 0, 0);
  }
  void FlushPhysicalControl() {
    if (!physicalTakePending)
      return;
    physicalTakePending = false;
    controlState = "user_control";
    FinishAllAgent("user_control");
    if (controlSink)
      controlSink("take", Active() ? Active()->agentId : "");
    Publish();
  }
  static bool PageOwnsTarget(const Impl *s, HWND target) noexcept {
    return s && s->alive && s->open && s->hwnd && IsWindowVisible(s->hwnd) &&
           target && (target == s->hwnd || IsChild(s->hwnd, target));
  }
  static LRESULT CALLBACK PhysicalMouseProc(int code, WPARAM message,
                                            LPARAM data) noexcept {
    if (code == HC_ACTION && data) {
      const auto &input = *reinterpret_cast<const MSLLHOOKSTRUCT *>(data);
      const HWND target = WindowFromPoint(input.pt);
      for (Impl *s : ThreadHooks().panels)
        if (s && BrowserPanel::IsPhysicalPageInput(
                     {static_cast<UINT>(message), input.flags, false,
                      PageOwnsTarget(s, target), false}))
          s->QueuePhysicalControl();
    }
    return CallNextHookEx(nullptr, code, message, data);
  }
  static LRESULT CALLBACK PhysicalKeyboardProc(int code, WPARAM message,
                                               LPARAM data) noexcept {
    if (code == HC_ACTION && data) {
      const auto &input = *reinterpret_cast<const KBDLLHOOKSTRUCT *>(data);
      GUITHREADINFO gui{sizeof(GUITHREADINFO)};
      const HWND foreground = GetForegroundWindow();
      if (foreground && GetGUIThreadInfo(0, &gui))
        for (Impl *s : ThreadHooks().panels)
          if (s && BrowserPanel::IsPhysicalPageInput(
                       {static_cast<UINT>(message), input.flags, true,
                        PageOwnsTarget(s, gui.hwndFocus),
                        GetAncestor(s->parent, GA_ROOT) == foreground}))
            s->QueuePhysicalControl();
    }
    return CallNextHookEx(nullptr, code, message, data);
  }
  bool RegisterPhysicalInput() {
    if (physicalRegistered)
      return true;
    auto &hooks = ThreadHooks();
    const auto slot =
        std::find(hooks.panels.begin(), hooks.panels.end(), nullptr);
    if (slot == hooks.panels.end())
      return false;
    if (!hooks.mouse)
      hooks.mouse = SetWindowsHookExW(WH_MOUSE_LL, PhysicalMouseProc,
                                      GetModuleHandleW(nullptr), 0);
    if (!hooks.keyboard)
      hooks.keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, PhysicalKeyboardProc,
                                         GetModuleHandleW(nullptr), 0);
    if (!hooks.mouse || !hooks.keyboard) {
      if (hooks.mouse)
        UnhookWindowsHookEx(hooks.mouse);
      if (hooks.keyboard)
        UnhookWindowsHookEx(hooks.keyboard);
      hooks.mouse = hooks.keyboard = nullptr;
      return false;
    }
    *slot = this;
    physicalRegistered = true;
    return true;
  }
  void UnregisterPhysicalInput() noexcept {
    if (!physicalRegistered)
      return;
    auto &hooks = ThreadHooks();
    for (auto &s : hooks.panels)
      if (s == this)
        s = nullptr;
    physicalRegistered = false;
    if (std::all_of(hooks.panels.begin(), hooks.panels.end(),
                    [](Impl *s) { return !s; })) {
      if (hooks.mouse)
        UnhookWindowsHookEx(hooks.mouse);
      if (hooks.keyboard)
        UnhookWindowsHookEx(hooks.keyboard);
      hooks.mouse = hooks.keyboard = nullptr;
    }
  }
  static bool HumanMessage(UINT message) {
    switch (message) {
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
    case WM_CHAR:
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_XBUTTONDOWN:
    case WM_MOUSEWHEEL:
    case WM_MOUSEHWHEEL:
    case WM_POINTERDOWN:
    case WM_POINTERWHEEL:
    case WM_POINTERHWHEEL:
    case WM_TOUCH:
      return true;
    default:
      return false;
    }
  }
  static LRESULT CALLBACK PageInputProc(HWND h, UINT m, WPARAM w, LPARAM l) {
    auto *hook =
        static_cast<InputHook *>(GetPropW(h, L"DevAgentsBrowserInput"));
    if (!hook)
      return DefWindowProcW(h, m, w, l);
    const auto previous = hook->previous;
    auto owner = hook->owner.lock();
    if (owner && owner->alive && HumanMessage(m)) {
      INPUT_MESSAGE_SOURCE source{};
      if (!GetCurrentInputMessageSource(&source) ||
          source.originId != IMO_INJECTED)
        owner->HumanControl();
    }
    if (m == WM_NCDESTROY) {
      RemovePropW(h, L"DevAgentsBrowserInput");
      SetWindowLongPtrW(h, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(previous));
      if (owner)
        owner->inputHooks.erase(h);
      delete hook;
    }
    return CallWindowProcW(previous, h, m, w, l);
  }
  void HookPageInput() {
    if (!hwnd)
      return;
    EnumChildWindows(
        hwnd,
        [](HWND h, LPARAM context) -> BOOL {
          auto *s = reinterpret_cast<Impl *>(context);
          DWORD pid = 0;
          const auto thread = GetWindowThreadProcessId(h, &pid);
          if (pid != GetCurrentProcessId() || thread != GetCurrentThreadId() ||
              s->inputHooks.count(h))
            return TRUE;
          auto *hook = new InputHook{s->weak_from_this(), nullptr};
          if (!SetPropW(h, L"DevAgentsBrowserInput", hook)) {
            delete hook;
            s->HumanControl();
            return TRUE;
          }
          SetLastError(ERROR_SUCCESS);
          const auto old = SetWindowLongPtrW(
              h, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(PageInputProc));
          if (!old) {
            RemovePropW(h, L"DevAgentsBrowserInput");
            delete hook;
            s->HumanControl();
            return TRUE;
          }
          hook->previous = reinterpret_cast<WNDPROC>(old);
          s->inputHooks.emplace(h, hook);
          return TRUE;
        },
        reinterpret_cast<LPARAM>(this));
  }
  std::shared_ptr<Tab> Active() const {
    return active < tabs.size() ? tabs[active] : nullptr;
  }
  std::shared_ptr<Tab> Find(unsigned id) const {
    for (const auto &t : tabs)
      if (t->id == id)
        return t;
    return nullptr;
  }
  bool Fixture(const std::wstring &url) const {
    std::string path;
    return !fixtureRoot.empty() && preview::UrlPath(url, path) &&
           browser::Policy::StaticAssetPath(path) &&
           preview::Resource(fixtureRoot, url);
  }
  bool Allowed(const std::wstring &url) const {
    return url == GuardUrl || policy.Allows(url) || Fixture(url);
  }
  // 12-nov: un archivo del proyecto se abre por el origen local controlado
  // https://preview.local/<ruta relativa>: los bytes los sirve el host desde
  // la carpeta de la orden con sus comprobaciones de confinamiento. Acepta
  // file:///…, una ruta absoluta de Windows o una ruta relativa que exista en
  // la carpeta. `file:` nunca llega al WebView.
  enum class LocalFile { NotLocal, Mapped, Outside };
  LocalFile ProjectUrl(const std::wstring &input, std::wstring &out) const {
    const auto lower = [](wchar_t c) {
      return c >= L'A' && c <= L'Z' ? static_cast<wchar_t>(c + 32) : c;
    };
    const auto drive = [](const std::wstring &p) {
      return p.size() > 2 && p[1] == L':' && (p[2] == L'\\' || p[2] == L'/') &&
             ((p[0] >= L'A' && p[0] <= L'Z') || (p[0] >= L'a' && p[0] <= L'z'));
    };
    if (input.empty() || input.size() > 8192)
      return LocalFile::NotLocal;
    std::wstring path;
    bool isFile = input.size() > 5;
    for (size_t i = 0; isFile && i < 5; ++i)
      isFile = lower(input[i]) == L"file:"[i];
    if (isFile) {
      // file:///C:/carpeta/p%C3%A1gina.html → C:/carpeta/página.html
      size_t at = 5;
      while (at < input.size() && input[at] == L'/')
        ++at;
      const std::string encoded = preview::Narrow(
          input.substr(at, input.find_first_of(L"?#", at) - at));
      std::string bytes;
      for (size_t i = 0; i < encoded.size(); ++i) {
        if (encoded[i] != '%') {
          bytes += encoded[i];
          continue;
        }
        if (i + 2 >= encoded.size())
          return LocalFile::Outside;
        const int a = preview::HexByte(encoded[i + 1]);
        const int b = preview::HexByte(encoded[i + 2]);
        if (a < 0 || b < 0)
          return LocalFile::Outside;
        bytes += static_cast<char>((a << 4) | b);
        i += 2;
      }
      path = preview::Wide(bytes);
      if (!drive(path))
        return LocalFile::Outside;
    } else if (drive(input)) {
      path = input;
    } else {
      // Ruta relativa: solo si de verdad existe ese archivo en la carpeta; así
      // «example.com» o «localhost:3000» siguen siendo direcciones.
      if (fixtureRoot.empty() || input.find(L':') != std::wstring::npos ||
          input.find_first_of(L"?#*<>|\"") != std::wstring::npos ||
          input[0] == L'/' || input[0] == L'\\')
        return LocalFile::NotLocal;
      path = fixtureRoot + L"\\" + input;
      const DWORD attrs = GetFileAttributesW(path.c_str());
      if (attrs == INVALID_FILE_ATTRIBUTES ||
          (attrs & FILE_ATTRIBUTE_DIRECTORY))
        return LocalFile::NotLocal;
    }
    if (fixtureRoot.empty())
      return LocalFile::Outside;
    for (auto &c : path)
      if (c == L'/')
        c = L'\\';
    // Ruta final real (sin enlaces ni «..») y confinada a la carpeta.
    const HANDLE h = CreateFileW(
        path.c_str(), FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
        OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (h == INVALID_HANDLE_VALUE)
      return LocalFile::Outside;
    const std::wstring real = preview::FinalPath(h);
    CloseHandle(h);
    if (!preview::Within(fixtureRoot, real))
      return LocalFile::Outside;
    std::wstring relative = real.substr(fixtureRoot.size());
    while (!relative.empty() && relative[0] == L'\\')
      relative.erase(0, 1);
    for (auto &c : relative)
      if (c == L'\\')
        c = L'/';
    const std::string utf8 = preview::Narrow(relative);
    if (!browser::Policy::StaticAssetPath(utf8))
      return LocalFile::Outside;
    static constexpr char hex[] = "0123456789ABCDEF";
    out = L"https://preview.local/";
    for (const unsigned char c : utf8) {
      if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
          (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' ||
          c == '~' || c == '/')
        out += static_cast<wchar_t>(c);
      else {
        out += L'%';
        out += static_cast<wchar_t>(hex[c >> 4]);
        out += static_cast<wchar_t>(hex[c & 15]);
      }
    }
    return LocalFile::Mapped;
  }
  bool CanOpen(const std::wstring &url) const {
    return Allowed(url) || url == L"about:blank";
  }
  const char *TrustOf(const std::wstring &url) const {
    if (Blank(url))
      return "none";
    if (Fixture(url))
      return "fixture";
    if (policy.IsApp(url))
      return "app";
    return policy.IsApproved(url) ? "approved" : "none";
  }
  // The state the trusted UI renders; every string is escaped to ASCII.
  std::string State() const {
    int panelPx = 0;
    RECT r{};
    if (open && hwnd && !full && GetWindowRect(hwnd, &r))
      panelPx = r.right - r.left;
    std::string j =
        std::string("{\"open\":") + Flag(open) + ",\"full\":" + Flag(full) +
        ",\"ready\":" + Flag(env) + ",\"covered\":" + Flag(covered) +
        ",\"bar_css\":" + std::to_string(BrowserPanel::BarCssHeight) +
        ",\"panel_px\":" + std::to_string(panelPx) +
        ",\"active\":" + std::to_string(Active() ? Active()->id : 0u) +
        ",\"session_id\":" + JsonText(preview::Wide(sessionId), 256) +
        ",\"control_state\":" +
        JsonText(
            preview::Wide(physicalTakePending ? "user_control" : controlState),
            32) +
        ",\"control_epoch\":" + std::to_string(controlEpoch) +
        ",\"status\":" + JsonText(status) +
        ",\"status_error\":" + Flag(statusError) + ",\"tabs\":[";
    for (size_t i = 0; i < tabs.size(); ++i) {
      const auto &t = *tabs[i];
      const auto origin = browser::Policy::Origin(t.url);
      if (i)
        j += ",";
      j += "{\"id\":" + std::to_string(t.id) + ",\"title\":" +
           JsonText(Blank(t.url) ? L"Nueva pestaña" : t.title, 160) +
           ",\"agent_id\":" + JsonText(preview::Wide(t.agentId), 256) +
           ",\"url\":" + JsonText(Blank(t.url) ? L"" : t.url) +
           ",\"origin\":" + JsonText(origin, 300) + ",\"trust\":\"" +
           TrustOf(t.url) + "\",\"loading\":" + Flag(t.loading) +
           ",\"ready\":" + Flag(t.ready) + ",\"can_back\":" + Flag(t.canBack) +
           ",\"can_forward\":" + Flag(t.canForward) + ",\"error\":";
      j += t.hasError ? "{\"code\":" + std::to_string(t.errorCode) +
                            ",\"detail\":" + JsonText(t.errorDetail, 120) +
                            ",\"reason\":" + JsonText(t.error, 300) + "}"
                      : "null";
      j += ",\"blocked\":";
      j += t.blocked
               ? "{\"origin\":" +
                     JsonText(browser::Policy::Origin(t.blockedUrl), 300) +
                     ",\"url\":" + JsonText(t.blockedUrl) +
                     ",\"reason\":" + JsonText(t.blockedReason, 300) + "}"
               : "null";
      j += "}";
    }
    j += "],\"approvals\":[";
    for (size_t i = 0; i < approvals.size(); ++i) {
      if (i)
        j += ",";
      j += "{\"id\":\"" + approvals[i].id +
           "\",\"origin\":" + JsonText(approvals[i].origin, 300) +
           ",\"source\":\"" + approvals[i].source + "\"}";
    }
    return j + "]}";
  }
  bool Publish() {
    if (!alive || !sink)
      return false;
    return sink(preview::Wide(
        "{\"push\":\"browser.state\",\"payload\":" + State() + "}"));
  }
  void AgentTitle(const std::string &id, size_t index) {
    auto it = agentPending.find(id);
    if (it == agentPending.end())
      return;
    if (GetTickCount64() >= it->second.deadline) {
      FinishAgent(id, "timeout");
      return;
    }
    if (physicalTakePending || controlState != "agent_control" ||
        it->second.epoch != controlEpoch) {
      FinishAgent(id, "user_control");
      return;
    }
    if (index == it->second.tabs.size()) {
      std::string result =
          "{\"request_id\":" + JsonText(preview::Wide(id), 256) +
          ",\"ok\":true,\"result\":{\"tabs\":[";
      bool first = true;
      for (const unsigned tabId : it->second.tabs) {
        const auto tab = Find(tabId);
        if (!tab || tab->closed) {
          FinishAgent(id, "tab_not_found");
          return;
        }
        if (!first)
          result += ',';
        first = false;
        result += "{\"id\":" + JsonText(preview::Wide(tab->agentId), 256) +
                  ",\"title\":" + JsonText(it->second.titles.at(tabId), 160) +
                  ",\"active\":" + Flag(it->second.active == tabId) + "}";
      }
      result += "]";
      if (!it->second.extraTab.empty())
        result +=
            ",\"tab_id\":" + JsonText(preview::Wide(it->second.extraTab), 256);
      result += "}}";
      auto done = std::move(it->second.done);
      agentPending.erase(it);
      done(std::move(result));
      return;
    }
    const auto tab = Find(it->second.tabs[index]);
    if (!tab || tab->closed) {
      FinishAgent(id, "tab_not_found");
      return;
    }
    if (!tab->view || !tab->ready) {
      // 12-nov: una pestaña recién creada que aún se prepara figura en la
      // lista sin título en vez de hacer fallar todo el listado.
      it->second.titles[tab->id] = L"";
      AgentTitle(id, index + 1);
      return;
    }
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    auto *callback =
        new Handler<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
                    HRESULT, LPCWSTR>(
            IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
            [weak, wt, id, index](HRESULT hr, LPCWSTR json) {
              auto s = weak.lock();
              if (!s || !s->alive)
                return S_OK;
              auto pending = s->agentPending.find(id);
              // A cancelled/closed/revoked operation must not touch the tab.
              if (pending == s->agentPending.end())
                return S_OK;
              if (GetTickCount64() >= pending->second.deadline) {
                s->FinishAgent(id, "timeout");
                return S_OK;
              }
              if (s->physicalTakePending ||
                  s->controlState != "agent_control" ||
                  pending->second.epoch != s->controlEpoch) {
                s->FinishAgent(id, "user_control");
                return S_OK;
              }
              auto t = wt.lock();
              if (!t || t->closed) {
                s->FinishAgent(id, "tab_not_found");
                return S_OK;
              }
              preview::Value value;
              if (FAILED(hr) || !json || wcsnlen_s(json, 4097) > 4096 ||
                  !preview::Parser(preview::Narrow(json), true, true)
                       .Parse(value) ||
                  !value.object.count("result") ||
                  !preview::Text(value.object.at("result"), "value", 2048,
                                 true)) {
                s->FinishAgent(id, "host_unavailable");
                return S_OK;
              }
              pending->second.titles[t->id] = CleanTitle(preview::Wide(
                  value.object.at("result").object.at("value").string));
              s->AgentTitle(id, index + 1);
              return S_OK;
            });
    // Fixed host operation. The request never chooses CDP methods or code.
    const HRESULT hr = tab->view->CallDevToolsProtocolMethod(
        L"Runtime.evaluate",
        LR"cdp({"expression":"document.title.slice(0,160).toWellFormed()","returnByValue":true,"timeout":5000})cdp",
        callback);
    callback->Release();
    if (FAILED(hr))
      FinishAgent(id, "host_unavailable");
  }
  // 11-nov: texto visible de la página, recortado a 8000 caracteres (con el
  // escape \uXXXX cabe en el límite de 64 KB del puente y en el del motor).
  static constexpr size_t AgentTextMax = 8000;
  void AgentText(const std::string &id, const std::shared_ptr<Tab> &tab) {
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    auto *callback =
        new Handler<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
                    HRESULT, LPCWSTR>(
            IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
            [weak, wt, id](HRESULT hr, LPCWSTR json) {
              auto s = weak.lock();
              if (!s || !s->alive)
                return S_OK;
              auto pending = s->agentPending.find(id);
              if (pending == s->agentPending.end())
                return S_OK;
              if (GetTickCount64() >= pending->second.deadline) {
                s->FinishAgent(id, "timeout");
                return S_OK;
              }
              if (s->physicalTakePending ||
                  s->controlState != "agent_control" ||
                  pending->second.epoch != s->controlEpoch) {
                s->FinishAgent(id, "user_control");
                return S_OK;
              }
              auto t = wt.lock();
              if (!t || t->closed) {
                s->FinishAgent(id, "tab_not_found");
                return S_OK;
              }
              constexpr size_t kRawLimit = 512 * 1024;
              preview::Value outer, inner;
              if (FAILED(hr) || !json ||
                  wcsnlen_s(json, kRawLimit + 1) > kRawLimit ||
                  !preview::Parser(preview::Narrow(json, kRawLimit), true, true,
                                   kRawLimit, 8)
                       .Parse(outer) ||
                  !outer.object.count("result") ||
                  !preview::Text(outer.object.at("result"), "value", kRawLimit,
                                 true) ||
                  !preview::Parser(
                       outer.object.at("result").object.at("value").string,
                       true, true, kRawLimit, 4)
                       .Parse(inner) ||
                  !preview::Text(inner, "t", kRawLimit, true) ||
                  !preview::Text(inner, "u", 8192, true)) {
                s->FinishAgent(id, "host_unavailable");
                return S_OK;
              }
              const auto truncated = inner.object.find("x");
              const bool cut =
                  truncated != inner.object.end() &&
                  truncated->second.type == preview::Value::Boolean &&
                  truncated->second.number != 0;
              const std::string result =
                  "{\"request_id\":" + JsonText(preview::Wide(id), 256) +
                  ",\"ok\":true,\"result\":{\"text\":" +
                  JsonText(preview::Wide(inner.object.at("t").string),
                           AgentTextMax) +
                  ",\"url\":" +
                  JsonText(preview::Wide(inner.object.at("u").string), 2048) +
                  ",\"truncated\":" + Flag(cut) + "}}";
              auto done = std::move(pending->second.done);
              s->agentPending.erase(pending);
              done(result);
              return S_OK;
            });
    // Expresión fija del host: la petición nunca elige código ni método CDP.
    const HRESULT hr = tab->view->CallDevToolsProtocolMethod(
        L"Runtime.evaluate",
        LR"cdp({"expression":"(()=>{const t=((document.body&&document.body.innerText)||'');return JSON.stringify({u:String(location.href).slice(0,2048),t:t.slice(0,8000),x:t.length>8000});})().toWellFormed()","returnByValue":true,"timeout":5000})cdp",
        callback);
    callback->Release();
    if (FAILED(hr))
      FinishAgent(id, "host_unavailable");
  }
  // ---- 12-nov: resto de acciones del agente ------------------------------
  // JSON en UTF-8 de un valor ya analizado (los datos de la página se
  // reenvían como datos, nunca como texto sin escapar).
  static std::string JsonQuote(const std::string &s) {
    static constexpr char hex[] = "0123456789abcdef";
    std::string out = "\"";
    for (const unsigned char c : s) {
      if (c == '"' || c == '\\') {
        out += '\\';
        out += static_cast<char>(c);
      } else if (c < 0x20 || c == 0x7f) {
        out += "\\u00";
        out += hex[c >> 4];
        out += hex[c & 15];
      } else
        out += static_cast<char>(c);
    }
    return out + '"';
  }
  static std::string JsonOf(const preview::Value &v) {
    switch (v.type) {
    case preview::Value::String:
      return JsonQuote(v.string);
    case preview::Value::Number: {
      char text[40];
      if (v.number == std::floor(v.number) && std::fabs(v.number) < 9e15)
        std::snprintf(text, sizeof(text), "%.0f", v.number);
      else
        std::snprintf(text, sizeof(text), "%.6g", v.number);
      return text;
    }
    case preview::Value::Boolean:
      return v.number ? "true" : "false";
    case preview::Value::Null:
      return "null";
    case preview::Value::Array: {
      std::string out = "[";
      for (const auto &item : v.array) {
        if (out.size() > 1)
          out += ',';
        out += JsonOf(item);
      }
      return out + ']';
    }
    case preview::Value::Object: {
      std::string out = "{";
      for (const auto &entry : v.object) {
        if (out.size() > 1)
          out += ',';
        out += JsonQuote(entry.first) + ':' + JsonOf(entry.second);
      }
      return out + '}';
    }
    }
    return "null";
  }
  // Códigos que el script fijo puede devolver; cualquier otro es un fallo de
  // protocolo (la página no elige el código que ve el modelo).
  static const char *ScriptCode(const std::string &code) {
    for (const char *known :
         {"invalid_arguments", "stale_reference", "stale_view",
          "element_not_found", "not_visible", "not_interactable", "occluded",
          "sensitive_field_denied", "not_editable", "backend_unsupported",
          "timeout"})
      if (code == known)
        return known;
    return "protocol_error";
  }
  void AgentOk(const std::string &id, const std::string &resultJson) {
    const auto it = agentPending.find(id);
    if (it == agentPending.end())
      return;
    auto done = std::move(it->second.done);
    agentPending.erase(it);
    done("{\"request_id\":" + JsonText(preview::Wide(id), 256) +
         ",\"ok\":true,\"result\":" + resultJson + "}");
  }
  using AgentStep =
      std::function<void(const std::shared_ptr<Tab> &, const preview::Value &)>;
  // Una llamada CDP de una operación del agente. Antes de continuar comprueba
  // que la petición sigue viva, en plazo, con el control del agente y sobre
  // una pestaña que existe. Un fallo aquí nunca cierra la pestaña (no es el
  // guard de aislamiento): termina la petición con su código. `onFail`, si se
  // da, sustituye al cierre con host_unavailable cuando falla la llamada
  // misma (contexto destruido por una navegación, respuesta ilegible).
  void AgentCdp(const std::string &id, const std::shared_ptr<Tab> &tab,
                const wchar_t *method, const std::wstring &params,
                AgentStep next, std::function<void()> onFail = {},
                size_t kRaw = 512 * 1024) {
    if (!tab || !tab->view || tab->closed) {
      FinishAgent(id, "tab_not_found");
      return;
    }
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    auto *callback =
        new Handler<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
                    HRESULT, LPCWSTR>(
            IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
            [weak, wt, id, next, onFail, kRaw](HRESULT hr, LPCWSTR json) {
              auto s = weak.lock();
              if (!s || !s->alive)
                return S_OK;
              const auto pending = s->agentPending.find(id);
              if (pending == s->agentPending.end())
                return S_OK;
              if (GetTickCount64() >= pending->second.deadline) {
                s->FinishAgent(id, "timeout");
                return S_OK;
              }
              if (s->physicalTakePending ||
                  s->controlState != "agent_control" ||
                  pending->second.epoch != s->controlEpoch) {
                s->FinishAgent(id, "user_control");
                return S_OK;
              }
              const auto t = wt.lock();
              if (!t || t->closed) {
                s->FinishAgent(id, "tab_not_found");
                return S_OK;
              }
              preview::Value value;
              const std::string raw =
                  SUCCEEDED(hr) && json && wcsnlen_s(json, kRaw + 1) <= kRaw
                      ? preview::Narrow(json, kRaw)
                      : std::string();
              if (raw.empty() ||
                  !preview::Parser(raw, true, true, kRaw, 12, 32, 512)
                       .Parse(value) ||
                  value.type != preview::Value::Object) {
                if (onFail)
                  onFail();
                else
                  s->FinishAgent(id, "host_unavailable");
                return S_OK;
              }
              next(t, value);
              return S_OK;
            });
    const HRESULT hr =
        tab->view->CallDevToolsProtocolMethod(method, params.c_str(), callback);
    callback->Release();
    if (FAILED(hr)) {
      if (onFail)
        onFail();
      else
        FinishAgent(id, "host_unavailable");
    }
  }
  // Evalúa el script fijo en un contexto ya creado y entrega su `result`.
  void AgentEval(const std::string &id, const std::shared_ptr<Tab> &tab,
                 int world, const std::string &op, const std::string &argsJson,
                 AgentStep done, std::function<void()> onFail) {
    const std::string expression = std::string("(") + browser_agent::Script +
                                   ")(" + JsonQuote(op) + "," + argsJson + ")";
    AgentCdp(
        id, tab, L"Runtime.evaluate",
        L"{\"expression\":" + preview::Wide(JsonQuote(expression)) +
            L",\"contextId\":" + std::to_wstring(world) +
            L",\"returnByValue\":true,\"awaitPromise\":true,\"timeout\":4000}",
        [this, id, done, onFail](const std::shared_ptr<Tab> &t,
                                 const preview::Value &reply) {
          constexpr size_t kRaw = 512 * 1024;
          const auto result = reply.object.find("result");
          preview::Value inner;
          if (result == reply.object.end() ||
              !preview::Text(result->second, "value", kRaw) ||
              !preview::Parser(result->second.object.at("value").string, true,
                               true, kRaw, 8, 16, 512)
                   .Parse(inner) ||
              inner.type != preview::Value::Object ||
              !inner.object.count("ok") ||
              inner.object.at("ok").type != preview::Value::Boolean) {
            if (onFail)
              onFail();
            else
              FinishAgent(id, "host_unavailable");
            return;
          }
          if (inner.object.at("ok").number != 1) {
            FinishAgent(id, preview::Text(inner, "code", 64)
                                ? ScriptCode(inner.object.at("code").string)
                                : "protocol_error");
            return;
          }
          const auto value = inner.object.find("result");
          if (value == inner.object.end() ||
              value->second.type != preview::Value::Object) {
            FinishAgent(id, "protocol_error");
            return;
          }
          done(t, value->second);
        },
        onFail);
  }
  // Ejecuta una operación del script fijo en el mundo aislado de la pestaña.
  // El mundo se crea una vez por documento y se reutiliza, para que las
  // referencias de un snapshot sigan valiendo en el clic siguiente. Si el
  // contexto guardado ya no existe, se crea otro una sola vez.
  void AgentScript(const std::string &id, const std::shared_ptr<Tab> &tab,
                   const std::string &op, const std::string &argsJson,
                   AgentStep done, std::function<void()> onFail = {}) {
    if (tab && tab->agentWorld) {
      const int world = tab->agentWorld;
      std::weak_ptr<Tab> wt = tab;
      AgentEval(id, tab, world, op, argsJson, done,
                [this, id, wt, world, op, argsJson, done, onFail] {
                  if (onFail) {
                    onFail();
                    return;
                  }
                  const auto t = wt.lock();
                  if (!t || t->closed) {
                    FinishAgent(id, "tab_not_found");
                    return;
                  }
                  if (t->agentWorld == world)
                    t->agentWorld = 0;
                  AgentScript(id, t, op, argsJson, done);
                });
      return;
    }
    const auto broken = [this, id, onFail] {
      if (onFail)
        onFail();
      else
        FinishAgent(id, "host_unavailable");
    };
    AgentCdp(
        id, tab, L"Page.getFrameTree", L"{}",
        [this, id, op, argsJson, done, onFail,
         broken](const std::shared_ptr<Tab> &t, const preview::Value &tree) {
          const auto root = tree.object.find("frameTree");
          if (root == tree.object.end() ||
              root->second.type != preview::Value::Object) {
            broken();
            return;
          }
          const auto frame = root->second.object.find("frame");
          if (frame == root->second.object.end() ||
              !preview::Text(frame->second, "id", 128)) {
            broken();
            return;
          }
          AgentCdp(
              id, t, L"Page.createIsolatedWorld",
              L"{\"frameId\":" +
                  preview::Wide(
                      JsonQuote(frame->second.object.at("id").string)) +
                  L",\"worldName\":\"devagents-agent\"}",
              [this, id, op, argsJson, done, onFail, broken](
                  const std::shared_ptr<Tab> &t2, const preview::Value &world) {
                if (!preview::Number(world, "executionContextId", 1,
                                     2147483647.0)) {
                  broken();
                  return;
                }
                t2->agentWorld = static_cast<int>(
                    world.object.at("executionContextId").number);
                AgentEval(id, t2, t2->agentWorld, op, argsJson, done, onFail);
              },
              onFail);
        },
        onFail);
  }
  // Envía en orden una lista cerrada de eventos CDP `Input` y termina.
  struct InputStep {
    const wchar_t *method;
    std::wstring params;
  };
  void AgentInput(const std::string &id, const std::shared_ptr<Tab> &tab,
                  std::shared_ptr<std::vector<InputStep>> steps, size_t index,
                  std::function<void(const std::shared_ptr<Tab> &)> finish) {
    if (index >= steps->size()) {
      finish(tab);
      return;
    }
    AgentCdp(id, tab, (*steps)[index].method, (*steps)[index].params,
             [this, id, steps, index, finish](const std::shared_ptr<Tab> &t,
                                              const preview::Value &) {
               AgentInput(id, t, steps, index + 1, finish);
             });
  }
  static std::wstring Num(double v) {
    wchar_t text[40];
    swprintf_s(text, L"%.2f", v);
    return text;
  }
  // Tras una acción con efecto: estado nuevo de la vista (URL, título,
  // revisión), para que el modelo no tenga que adivinar si cambió algo. Si la
  // página ya está navegando, el efecto está hecho: se informa con lo que
  // sabe el host y `page_changed`.
  void AgentAfter(const std::string &id, const std::shared_ptr<Tab> &tab,
                  const std::string &prefix,
                  const std::string &stateArgs = "{}") {
    std::weak_ptr<Tab> wt = tab;
    AgentScript(
        id, tab, "state", stateArgs,
        [this, id, prefix](const std::shared_ptr<Tab> &,
                           const preview::Value &state) {
          const std::string body = JsonOf(state);
          AgentOk(id, "{" + prefix +
                          (body.size() > 2 ? "," + body.substr(1) : "}"));
        },
        [this, id, prefix, wt] {
          const auto t = wt.lock();
          LPWSTR source = nullptr;
          std::wstring url;
          if (t && t->view && SUCCEEDED(t->view->get_Source(&source)) && source)
            url = source;
          if (source)
            CoTaskMemFree(source);
          AgentOk(id, "{" + prefix + ",\"page_changed\":true,\"url\":" +
                          JsonText(url, 2048) + "}");
        });
  }
  // T6: browser_wait. El script espera dentro de la página tramos de hasta
  // 3 s; aquí se repiten hasta que se cumple, hasta `until` (condition=time)
  // o hasta el plazo de la petición (timeout). Si una navegación destruye el
  // mundo aislado, se crea otro y se sigue esperando (con tope de intentos).
  void AgentWait(const std::string &id, const std::shared_ptr<Tab> &tab,
                 const std::string &base, ULONGLONG until, int retries) {
    const auto pending = agentPending.find(id);
    if (pending == agentPending.end())
      return;
    const ULONGLONG now = GetTickCount64();
    const ULONGLONG end = until ? until : pending->second.deadline;
    const ULONGLONG margin = until ? 0 : 300;
    if (!until && now + margin >= end) {
      FinishAgent(id, "timeout");
      return;
    }
    const ULONGLONG budget =
        std::min<ULONGLONG>(3000, end > now + margin ? end - now - margin : 0);
    std::weak_ptr<Tab> wt = tab;
    AgentScript(
        id, tab, "wait", base + ",\"budget\":" + std::to_string(budget) + "}",
        [this, id, base, until, retries](const std::shared_ptr<Tab> &t,
                                         const preview::Value &r) {
          const auto met = r.object.find("met");
          const bool done = met != r.object.end() &&
                            met->second.type == preview::Value::Boolean &&
                            met->second.number == 1;
          if (until ? GetTickCount64() >= until && done : done) {
            AgentOk(id, JsonOf(r));
            return;
          }
          AgentWait(id, t, base, until, retries);
        },
        [this, id, wt, base, until, retries] {
          const auto t = wt.lock();
          if (!t || t->closed) {
            FinishAgent(id, "tab_not_found");
            return;
          }
          if (retries >= 100) {
            FinishAgent(id, "host_unavailable");
            return;
          }
          t->agentWorld = 0;
          AgentWait(id, t, base, until, retries + 1);
        });
  }
  // T6: guarda una captura en <carpeta de la orden>\.devagents-browser\ con
  // nombre nuevo (nunca sobrescribe) y devuelve su ruta relativa. Sin
  // carpeta de la orden, o si la subcarpeta es un enlace, no se guarda.
  unsigned shotCounter = 0;
  bool SaveShot(const std::string &png, std::string &relative) {
    if (fixtureRoot.empty())
      return false;
    const std::wstring dir = fixtureRoot + L"\\.devagents-browser";
    if (!CreateDirectoryW(dir.c_str(), nullptr) &&
        GetLastError() != ERROR_ALREADY_EXISTS)
      return false;
    const DWORD attributes = GetFileAttributesW(dir.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        !(attributes & FILE_ATTRIBUTE_DIRECTORY) ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
      return false;
    SYSTEMTIME now{};
    GetLocalTime(&now);
    wchar_t name[96];
    swprintf_s(name, L"captura-%04u%02u%02u-%02u%02u%02u-%u.png", now.wYear,
               now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
               ++shotCounter);
    const std::wstring path = dir + L"\\" + name;
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE)
      return false;
    DWORD written = 0;
    const BOOL ok = WriteFile(file, png.data(), static_cast<DWORD>(png.size()),
                              &written, nullptr);
    CloseHandle(file);
    if (!ok || written != png.size()) {
      DeleteFileW(path.c_str());
      return false;
    }
    relative = ".devagents-browser/" + preview::Narrow(name);
    return true;
  }
  // T6: browser_screenshot. Page.captureScreenshot (PNG, solo lo visible o
  // el recorte `clip`) y se guarda como evidencia: los proveedores de la
  // orden reciben resultados de herramienta solo como texto
  // (connector_v2_bridge), así que el modelo recibe ruta, bytes y tamaño.
  void AgentShot(const std::string &id, const std::shared_ptr<Tab> &tab,
                 const std::wstring &clip, double revision) {
    AgentCdp(
        id, tab, L"Page.captureScreenshot",
        L"{\"format\":\"png\",\"captureBeyondViewport\":false" + clip + L"}",
        [this, id, revision](const std::shared_ptr<Tab> &,
                             const preview::Value &shot) {
          std::string png;
          uint32_t width = 0, height = 0;
          if (!preview::Text(shot, "data", 12u * 1024u * 1024u) ||
              !browser_agent::Base64Decode(shot.object.at("data").string,
                                           png) ||
              !browser_agent::PngSize(png, width, height)) {
            FinishAgent(id, "protocol_error");
            return;
          }
          std::string relative;
          if (!SaveShot(png, relative)) {
            FinishAgent(id, "evidence_unavailable");
            return;
          }
          char rev[32];
          std::snprintf(rev, sizeof rev, "%.0f", revision);
          AgentOk(id,
                  "{\"path\":" + JsonQuote(relative) +
                      ",\"bytes\":" + std::to_string(png.size()) +
                      ",\"width\":" + std::to_string(width) +
                      ",\"height\":" + std::to_string(height) +
                      ",\"format\":\"png\",\"view_revision\":" + rev +
                      ",\"delivered_as\":\"file\",\"note\":" +
                      JsonQuote("El proveedor de esta orden recibe los "
                                "resultados de herramienta solo como texto: la "
                                "captura no se adjunta como imagen; se guardó "
                                "como archivo de evidencia en la carpeta de la "
                                "orden (path es relativa a ella).") +
                      "}");
        },
        {}, 16u * 1024u * 1024u);
  }
  // Punto válido devuelto por la operación `point` del script.
  static bool PointOf(const preview::Value &at, double &x, double &y) {
    if (!preview::Number(at, "x", 0, 100000) ||
        !preview::Number(at, "y", 0, 100000))
      return false;
    x = at.object.at("x").number;
    y = at.object.at("y").number;
    return true;
  }
  static std::wstring MouseAt(const wchar_t *type, double x, double y,
                              const wchar_t *button, int buttons,
                              int clicks = 0) {
    return std::wstring(L"{\"type\":\"") + type + L"\",\"x\":" + Num(x) +
           L",\"y\":" + Num(y) + L",\"button\":\"" + button +
           L"\",\"buttons\":" + std::to_wstring(buttons) +
           (clicks ? L",\"clickCount\":" + std::to_wstring(clicks)
                   : std::wstring()) +
           L"}";
  }
  // T6: browser_fill_form, campo a campo y en orden, después de que el script
  // haya comprobado TODOS los campos (formcheck). Las mismas reglas que
  // browser_type: nunca contraseñas ni pago; el texto escrito no se devuelve,
  // solo cuántos caracteres.
  void AgentFill(const std::string &id, const std::shared_ptr<Tab> &tab,
                 std::shared_ptr<const std::vector<preview::Value>> fields,
                 size_t index, const std::string &results) {
    if (index >= fields->size()) {
      AgentAfter(id, tab,
                 "\"filled\":" + std::to_string(fields->size()) +
                     ",\"fields\":[" + results + "]");
      return;
    }
    const preview::Value &f = (*fields)[index];
    const std::string fieldKind = f.object.at("kind").string;
    const std::string field = JsonOf(f);
    const std::string sep = index ? "," : "";
    const std::string head = sep + "{\"index\":" + std::to_string(index) +
                             ",\"kind\":" + JsonQuote(fieldKind);
    if (fieldKind == "text") {
      const std::string text = f.object.at("value").string;
      AgentScript(
          id, tab, "typeprep",
          "{\"target\":" + JsonOf(f.object.at("target")) +
              ",\"mode\":\"replace\",\"empty\":" + Flag(text.empty()) + "}",
          [this, id, fields, index, results, head,
           text](const std::shared_ptr<Tab> &t, const preview::Value &) {
            auto steps = std::make_shared<std::vector<InputStep>>();
            if (!text.empty())
              steps->push_back(
                  {L"Input.insertText",
                   L"{\"text\":" + preview::Wide(JsonQuote(text)) + L"}"});
            const std::string done =
                results + head +
                ",\"chars\":" + std::to_string(preview::Wide(text).size()) +
                "}";
            AgentInput(id, t, steps, 0,
                       [this, id, fields, index,
                        done](const std::shared_ptr<Tab> &t2) {
                         AgentFill(id, t2, fields, index + 1, done);
                       });
          });
      return;
    }
    if (fieldKind == "select") {
      AgentScript(
          id, tab, "selectopt", field,
          [this, id, fields, index, results,
           head](const std::shared_ptr<Tab> &t, const preview::Value &chosen) {
            const std::string label =
                preview::Text(chosen, "selected", 512, true)
                    ? chosen.object.at("selected").string
                    : "";
            AgentFill(id, t, fields, index + 1,
                      results + head + ",\"selected\":" + JsonQuote(label) +
                          "}");
          });
      return;
    }
    // checkbox / radio: un clic real solo si hay que cambiar su estado.
    const bool want = f.object.at("value").number == 1;
    AgentScript(
        id, tab, "checkprep", field,
        [this, id, fields, index, results, head,
         want](const std::shared_ptr<Tab> &t, const preview::Value &prep) {
          const auto changed = prep.object.find("changed");
          const bool click = changed != prep.object.end() &&
                             changed->second.type == preview::Value::Boolean &&
                             changed->second.number == 1;
          const std::string done = results + head +
                                   ",\"checked\":" + Flag(want) +
                                   ",\"changed\":" + Flag(click) + "}";
          double x = 0, y = 0;
          if (!click) {
            AgentFill(id, t, fields, index + 1, done);
            return;
          }
          if (!PointOf(prep, x, y)) {
            FinishAgent(id, "protocol_error");
            return;
          }
          auto steps = std::make_shared<std::vector<InputStep>>();
          steps->push_back({L"Input.dispatchMouseEvent",
                            MouseAt(L"mouseMoved", x, y, L"none", 0)});
          steps->push_back({L"Input.dispatchMouseEvent",
                            MouseAt(L"mousePressed", x, y, L"left", 1, 1)});
          steps->push_back({L"Input.dispatchMouseEvent",
                            MouseAt(L"mouseReleased", x, y, L"left", 0, 1)});
          AgentInput(
              id, t, steps, 0,
              [this, id, fields, index, done](const std::shared_ptr<Tab> &t2) {
                AgentFill(id, t2, fields, index + 1, done);
              });
        });
  }
  // T6: browser_drag con los dos extremos ya resueltos en la misma vista.
  void AgentDragGo(const std::string &id, const std::shared_ptr<Tab> &tab,
                   double fx, double fy, double tx, double ty, int count) {
    auto steps = std::make_shared<std::vector<InputStep>>();
    steps->push_back({L"Input.dispatchMouseEvent",
                      MouseAt(L"mouseMoved", fx, fy, L"none", 0)});
    steps->push_back({L"Input.dispatchMouseEvent",
                      MouseAt(L"mousePressed", fx, fy, L"left", 1, 1)});
    for (int i = 1; i <= count; ++i)
      steps->push_back({L"Input.dispatchMouseEvent",
                        MouseAt(L"mouseMoved", fx + (tx - fx) * i / count,
                                fy + (ty - fy) * i / count, L"left", 1)});
    steps->push_back({L"Input.dispatchMouseEvent",
                      MouseAt(L"mouseReleased", tx, ty, L"left", 0, 1)});
    char where[160];
    std::snprintf(where, sizeof where,
                  "\"dragged\":true,\"from\":{\"x\":%.2f,\"y\":%.2f},"
                  "\"to\":{\"x\":%.2f,\"y\":%.2f},\"steps\":%d",
                  fx, fy, tx, ty, count);
    const std::string prefix = where;
    AgentInput(id, tab, steps, 0,
               [this, id, prefix](const std::shared_ptr<Tab> &t) {
                 AgentAfter(id, t, prefix);
               });
  }
  // T6: browser_debug_js en el mundo aislado "devagents-debug" (DebugScript).
  // `timeoutMs` es el tope de Runtime.evaluate (browser_tools.zig: 2000 ms
  // como máximo). Si el mundo guardado ya no existe se crea otro una vez.
  void AgentDebug(const std::string &id, const std::shared_ptr<Tab> &tab,
                  const std::string &code, int timeoutMs, bool retried) {
    const auto evaluate = [this, id, code, timeoutMs,
                           retried](const std::shared_ptr<Tab> &t, int world) {
      const std::string expression =
          std::string("(") + browser_agent::DebugScript + ")(" +
          JsonQuote(code) + "," + std::to_string(timeoutMs) + ")";
      std::weak_ptr<Tab> wt = t;
      const ULONGLONG started = GetTickCount64();
      AgentCdp(
          id, t, L"Runtime.evaluate",
          L"{\"expression\":" + preview::Wide(JsonQuote(expression)) +
              L",\"contextId\":" + std::to_wstring(world) +
              L",\"returnByValue\":true,\"awaitPromise\":true,\"timeout\":" +
              std::to_wstring(timeoutMs) + L"}",
          [this, id](const std::shared_ptr<Tab> &,
                     const preview::Value &reply) {
            constexpr size_t kRaw = 512 * 1024;
            // Sin valor y con excepción: el tope de tiempo cortó el código.
            const auto result = reply.object.find("result");
            preview::Value inner;
            if (result == reply.object.end() ||
                !preview::Text(result->second, "value", kRaw)) {
              FinishAgent(id, reply.object.count("exceptionDetails")
                                  ? "timeout"
                                  : "protocol_error");
              return;
            }
            if (!preview::Parser(result->second.object.at("value").string, true,
                                 true, kRaw, 8, 16, 512)
                     .Parse(inner) ||
                !inner.object.count("ok") ||
                inner.object.at("ok").type != preview::Value::Boolean) {
              FinishAgent(id, "protocol_error");
              return;
            }
            if (inner.object.at("ok").number != 1) {
              FinishAgent(id, preview::Text(inner, "code", 64)
                                  ? ScriptCode(inner.object.at("code").string)
                                  : "protocol_error");
              return;
            }
            const auto value = inner.object.find("result");
            if (value == inner.object.end() ||
                value->second.type != preview::Value::Object) {
              FinishAgent(id, "protocol_error");
              return;
            }
            AgentOk(id, JsonOf(value->second));
          },
          [this, id, wt, code, timeoutMs, retried, started] {
            const auto t2 = wt.lock();
            if (!t2 || t2->closed) {
              FinishAgent(id, "tab_not_found");
              return;
            }
            // Chromium responde con un error de protocolo cuando corta el
            // código por el tope de tiempo: eso es timeout, no se reintenta.
            if (GetTickCount64() - started >=
                static_cast<ULONGLONG>(timeoutMs)) {
              FinishAgent(id, "timeout");
              return;
            }
            if (retried) {
              FinishAgent(id, "host_unavailable");
              return;
            }
            t2->debugWorld = 0;
            AgentDebug(id, t2, code, timeoutMs, true);
          });
    };
    if (tab->debugWorld) {
      evaluate(tab, tab->debugWorld);
      return;
    }
    AgentCdp(
        id, tab, L"Page.getFrameTree", L"{}",
        [this, id, evaluate](const std::shared_ptr<Tab> &t,
                             const preview::Value &tree) {
          const auto root = tree.object.find("frameTree");
          if (root == tree.object.end() ||
              root->second.type != preview::Value::Object ||
              !root->second.object.count("frame") ||
              !preview::Text(root->second.object.at("frame"), "id", 128)) {
            FinishAgent(id, "host_unavailable");
            return;
          }
          AgentCdp(
              id, t, L"Page.createIsolatedWorld",
              L"{\"frameId\":" +
                  preview::Wide(JsonQuote(
                      root->second.object.at("frame").object.at("id").string)) +
                  L",\"worldName\":\"devagents-debug\"}",
              [this, id, evaluate](const std::shared_ptr<Tab> &t2,
                                   const preview::Value &world) {
                if (!preview::Number(world, "executionContextId", 1,
                                     2147483647.0)) {
                  FinishAgent(id, "host_unavailable");
                  return;
                }
                t2->debugWorld = static_cast<int>(
                    world.object.at("executionContextId").number);
                evaluate(t2, t2->debugWorld);
              });
        });
  }
  struct KeyInfo {
    const char *name, *code;
    int vk;
    const char *text;
  };
  // Teclas admitidas. Sin Win, Alt+F4, F12 ni atajos del sistema, de
  // DevTools o del portapapeles (contrato §3, browser_key → key_denied).
  static bool KeyFor(const std::string &key, KeyInfo &out, std::string &text) {
    static const KeyInfo table[] = {{"Enter", "Enter", 13, "\r"},
                                    {"Tab", "Tab", 9, ""},
                                    {"Escape", "Escape", 27, ""},
                                    {"Backspace", "Backspace", 8, ""},
                                    {"Delete", "Delete", 46, ""},
                                    {"ArrowLeft", "ArrowLeft", 37, ""},
                                    {"ArrowUp", "ArrowUp", 38, ""},
                                    {"ArrowRight", "ArrowRight", 39, ""},
                                    {"ArrowDown", "ArrowDown", 40, ""},
                                    {"Home", "Home", 36, ""},
                                    {"End", "End", 35, ""},
                                    {"PageUp", "PageUp", 33, ""},
                                    {"PageDown", "PageDown", 34, ""},
                                    {"Space", "Space", 32, " "},
                                    {" ", "Space", 32, " "}};
    for (const auto &entry : table)
      if (key == entry.name) {
        out = entry;
        text = entry.text;
        return true;
      }
    if (key.size() == 1 && key[0] > 0x20 && key[0] < 0x7f) {
      const char c = key[0];
      const bool letter = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
      out = {nullptr, "", letter ? (c & ~0x20) : (c >= '0' && c <= '9' ? c : 0),
             ""};
      text = key;
      return true;
    }
    return false;
  }
  std::shared_ptr<Tab> AgentTab(const std::string &agentId) const {
    for (const auto &t : tabs)
      if (t->agentId == agentId && !t->closed)
        return t;
    return nullptr;
  }
  // Resultado de una navegación del agente que terminó bien.
  void AgentNavOk(const std::shared_ptr<Tab> &t) {
    const std::string id = t->agentNav;
    t->agentNav.clear();
    const auto pending = agentPending.find(id);
    if (pending == agentPending.end())
      return;
    if (pending->second.listAfter) {
      // browser_tabs create con url: el resultado es la lista de pestañas.
      pending->second.navTab = 0;
      pending->second.loadDeadline = 0;
      pending->second.tabs.clear();
      for (const auto &tab : tabs)
        pending->second.tabs.push_back(tab->id);
      pending->second.active = Active() ? Active()->id : 0;
      AgentTitle(id, 0);
      return;
    }
    LPWSTR source = nullptr;
    std::wstring url;
    if (t->view && SUCCEEDED(t->view->get_Source(&source)) && source)
      url = source;
    if (source)
      CoTaskMemFree(source);
    const std::string result =
        "{\"request_id\":" + JsonText(preview::Wide(id), 256) +
        ",\"ok\":true,\"result\":{\"url\":" + JsonText(url, 2048) + "}}";
    auto done = std::move(pending->second.done);
    agentPending.erase(pending);
    done(result);
  }
  void ExecuteAgent(const std::string &json, AgentCompletion done) {
    preview::Value request;
    std::string id;
    if (json.size() > 65536 ||
        !preview::Parser(json, true, true, 65536, 16).Parse(request) ||
        !preview::Text(request, "request_id", 256)) {
      done(AgentError(id, "invalid_arguments"));
      return;
    }
    id = request.object.at("request_id").string;
    const auto fail = [&](const std::string &code) {
      done(AgentError(id, code));
    };
    if (!alive || !open || sessionId.empty()) {
      fail("session_closed");
      return;
    }
    if (physicalTakePending || controlState != "agent_control") {
      fail(physicalTakePending || controlState == "user_control"
               ? "user_control"
               : "session_closed");
      return;
    }
    if (!preview::Number(request, "control_epoch", 0, 9007199254740991.0) ||
        request.object.at("control_epoch").number !=
            static_cast<double>(controlEpoch)) {
      fail("user_control");
      return;
    }
    const auto session = request.object.find("session_id");
    if (session != request.object.end() &&
        (session->second.type != preview::Value::String ||
         session->second.string != sessionId)) {
      fail("order_mismatch");
      return;
    }
    if (!preview::Text(request, "tool", 128)) {
      fail("invalid_arguments");
      return;
    }
    if (!preview::Number(request, "deadline_ms", 1, 9007199254740991.0)) {
      fail("invalid_arguments");
      return;
    }
    const auto deadline =
        static_cast<ULONGLONG>(request.object.at("deadline_ms").number);
    if (GetTickCount64() >= deadline) {
      fail("timeout");
      return;
    }
    const auto args = request.object.find(
        request.object.count("args") ? "args" : "arguments");
    // 11-nov: browser_text (scope=page) lee el texto visible de una pestaña
    // con una expresión FIJA del host; el modelo nunca elige código ni método
    // CDP. T6 (13-nov): las 15 herramientas restantes tienen aquí su camino;
    // backend_unsupported queda solo para una herramienta que el host no
    // conoce (app_server_* y browser_batch los resuelve el motor y nunca
    // llegan al panel).
    // 11-nov: browser_navigate (action=url) abre una dirección en una pestaña
    // conocida por el MISMO camino que la barra del panel (GoTab), así que la
    // política de orígenes y la aprobación del usuario se aplican igual. La
    // respuesta llega al terminar la navegación (NavigationCompleted).
    const std::string tool = request.object.at("tool").string;
    const bool hasArgs = args != request.object.end() &&
                         args->second.type == preview::Value::Object;
    // Reserva la petición (duplicados y cola) antes de cualquier efecto.
    // Tras reservar, `done` ya no es de esta función: no se usa `fail`.
    const auto claim = [&](unsigned tabId) {
      if (agentPending.count(id)) {
        fail("protocol_error");
        return false;
      }
      if (agentPending.size() >= 32) {
        fail("busy");
        return false;
      }
      AgentPending pending;
      pending.done = std::move(done);
      pending.epoch = controlEpoch;
      pending.deadline = deadline;
      pending.active = tabId;
      agentPending.emplace(id, std::move(pending));
      return true;
    };
    // Pestaña de una acción sobre la página: existe y enseña una página.
    const auto pageTab = [&]() -> std::shared_ptr<Tab> {
      if (!hasArgs || !preview::Text(args->second, "tab_id", 256)) {
        fail("invalid_arguments");
        return nullptr;
      }
      auto tab = AgentTab(args->second.object.at("tab_id").string);
      if (!tab) {
        fail("tab_not_found");
        return nullptr;
      }
      if (!tab->view || !tab->ready || tab->blocked || tab->hasError ||
          Blank(tab->url)) {
        fail("host_unavailable");
        return nullptr;
      }
      return tab;
    };
    const auto object = [&](const char *key) -> const preview::Value * {
      if (!hasArgs)
        return nullptr;
      const auto it = args->second.object.find(key);
      return it != args->second.object.end() &&
                     it->second.type == preview::Value::Object
                 ? &it->second
                 : nullptr;
    };
    const auto field = [](const preview::Value &v, const char *key,
                          size_t cap) {
      return preview::Text(v, key, cap, true) ? v.object.at(key).string
                                              : std::string();
    };
    const auto relay = [this, id](const std::shared_ptr<Tab> &,
                                  const preview::Value &result) {
      AgentOk(id, JsonOf(result));
    };
    if (tool == "browser_snapshot") {
      const auto tab = pageTab();
      if (tab && claim(tab->id))
        AgentScript(id, tab, "snapshot", "{}", relay);
      return;
    }
    if (tool == "browser_find") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const auto query = object("query");
      if (!query) {
        fail("invalid_arguments");
        return;
      }
      const std::string scriptArgs = "{\"query\":" + JsonOf(*query) + "}";
      if (claim(tab->id))
        AgentScript(id, tab, "find", scriptArgs, relay);
      return;
    }
    if (tool == "browser_text" && hasArgs &&
        preview::Text(args->second, "scope", 16) &&
        args->second.object.at("scope").string == "ref") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const auto target = object("target");
      if (!target) {
        fail("invalid_arguments");
        return;
      }
      const std::string scriptArgs = "{\"target\":" + JsonOf(*target) + "}";
      if (claim(tab->id))
        AgentScript(id, tab, "text", scriptArgs, relay);
      return;
    }
    if (tool == "browser_scroll") {
      const auto tab = pageTab();
      if (!tab)
        return;
      // dx es opcional (desplazamiento vertical por defecto).
      const bool hasDx = args->second.object.count("dx") != 0;
      if ((hasDx && !preview::Number(args->second, "dx", -10000, 10000)) ||
          !preview::Number(args->second, "dy", -10000, 10000)) {
        fail("invalid_arguments");
        return;
      }
      const auto target = object("target");
      const std::string scriptArgs =
          "{\"dx\":" +
          (hasDx ? JsonOf(args->second.object.at("dx")) : std::string("0")) +
          ",\"dy\":" + JsonOf(args->second.object.at("dy")) +
          (target ? ",\"target\":" + JsonOf(*target) : std::string()) + "}";
      if (claim(tab->id))
        AgentScript(id, tab, "scroll", scriptArgs, relay);
      return;
    }
    if (tool == "browser_click") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const auto target = object("target");
      const std::string button = preview::Text(args->second, "button", 8)
                                     ? args->second.object.at("button").string
                                     : "left";
      const int count =
          preview::Number(args->second, "count", 1, 2)
              ? static_cast<int>(args->second.object.at("count").number)
              : 1;
      if (!target ||
          (button != "left" && button != "right" && button != "middle")) {
        fail("invalid_arguments");
        return;
      }
      const std::string scriptArgs = "{\"target\":" + JsonOf(*target) + "}";
      if (!claim(tab->id))
        return;
      AgentScript(
          id, tab, "point", scriptArgs,
          [this, id, button, count, field](const std::shared_ptr<Tab> &t,
                                           const preview::Value &at) {
            if (!preview::Number(at, "x", 0, 100000) ||
                !preview::Number(at, "y", 0, 100000)) {
              FinishAgent(id, "protocol_error");
              return;
            }
            const std::wstring where =
                L",\"x\":" + Num(at.object.at("x").number) + L",\"y\":" +
                Num(at.object.at("y").number);
            const std::wstring name = preview::Wide(button);
            const wchar_t *mask = button == "left"    ? L"1"
                                  : button == "right" ? L"2"
                                                      : L"4";
            auto steps = std::make_shared<std::vector<InputStep>>();
            steps->push_back({L"Input.dispatchMouseEvent",
                              L"{\"type\":\"mouseMoved\"" + where +
                                  L",\"button\":\"none\",\"buttons\":0}"});
            for (int click = 1; click <= count; ++click) {
              steps->push_back(
                  {L"Input.dispatchMouseEvent",
                   L"{\"type\":\"mousePressed\"" + where + L",\"button\":\"" +
                       name + L"\",\"buttons\":" + mask + L",\"clickCount\":" +
                       std::to_wstring(click) + L"}"});
              steps->push_back({L"Input.dispatchMouseEvent",
                                L"{\"type\":\"mouseReleased\"" + where +
                                    L",\"button\":\"" + name +
                                    L"\",\"buttons\":0,\"clickCount\":" +
                                    std::to_wstring(click) + L"}"});
            }
            const std::string prefix =
                "\"clicked\":true,\"element\":{\"role\":" +
                JsonQuote(field(at, "role", 64)) +
                ",\"name\":" + JsonQuote(field(at, "name", 512)) +
                "},\"x\":" + JsonOf(at.object.at("x")) +
                ",\"y\":" + JsonOf(at.object.at("y"));
            AgentInput(id, t, steps, 0,
                       [this, id, prefix](const std::shared_ptr<Tab> &t2) {
                         AgentAfter(id, t2, prefix);
                       });
          });
      return;
    }
    if (tool == "browser_type") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const auto target = object("target");
      if (!target || !preview::Text(args->second, "text", 8192, true) ||
          !preview::Text(args->second, "mode", 8)) {
        fail("invalid_arguments");
        return;
      }
      const std::string text = args->second.object.at("text").string;
      const std::string mode = args->second.object.at("mode").string;
      if (mode != "replace" && mode != "append") {
        fail("invalid_arguments");
        return;
      }
      const std::string scriptArgs = "{\"target\":" + JsonOf(*target) +
                                     ",\"mode\":" + JsonQuote(mode) +
                                     ",\"empty\":" + Flag(text.empty()) + "}";
      if (!claim(tab->id))
        return;
      AgentScript(
          id, tab, "typeprep", scriptArgs,
          [this, id, text, field](const std::shared_ptr<Tab> &t,
                                  const preview::Value &input) {
            // Nunca se devuelve el texto escrito: solo cuántos caracteres.
            const std::string prefix =
                "\"typed\":" + std::to_string(preview::Wide(text).size()) +
                ",\"element\":{\"role\":" +
                JsonQuote(field(input, "role", 64)) +
                ",\"name\":" + JsonQuote(field(input, "name", 512)) + "}";
            auto steps = std::make_shared<std::vector<InputStep>>();
            if (!text.empty())
              steps->push_back(
                  {L"Input.insertText",
                   L"{\"text\":" + preview::Wide(JsonQuote(text)) + L"}"});
            AgentInput(id, t, steps, 0,
                       [this, id, prefix](const std::shared_ptr<Tab> &t2) {
                         AgentAfter(id, t2, prefix);
                       });
          });
      return;
    }
    if (tool == "browser_key") {
      const auto tab = pageTab();
      if (!tab)
        return;
      if (!preview::Text(args->second, "key", 64)) {
        fail("invalid_arguments");
        return;
      }
      const std::string key = args->second.object.at("key").string;
      int mods = 0;
      const auto list = args->second.object.find("modifiers");
      if (list != args->second.object.end() &&
          list->second.type == preview::Value::Array)
        for (const auto &m : list->second.array)
          if (m.type == preview::Value::String)
            mods |= m.string == "Alt"       ? 1
                    : m.string == "Control" ? 2
                    : m.string == "Meta"    ? 4
                    : m.string == "Shift"   ? 8
                                            : 0;
      KeyInfo info{};
      std::string text;
      // Alt y Meta nunca: atajos del sistema y del navegador.
      bool allowed = KeyFor(key, info, text) && !(mods & 5);
      std::wstring command;
      if (allowed && (mods & 2)) {
        // Con Control solo edición y movimiento; nada de portapapeles,
        // pestañas, DevTools ni atajos del sistema.
        const std::string k =
            key.size() == 1 ? std::string(1, static_cast<char>(key[0] | 0x20))
                            : key;
        allowed = k == "a" || k == "z" || k == "y" || k == "Enter" ||
                  k == "Home" || k == "End" || k == "ArrowLeft" ||
                  k == "ArrowRight" || k == "Backspace" || k == "Delete";
        command = k == "a"   ? L",\"commands\":[\"selectAll\"]"
                  : k == "z" ? L",\"commands\":[\"undo\"]"
                  : k == "y" ? L",\"commands\":[\"redo\"]"
                             : L"";
        text.clear();
      }
      if (!allowed) {
        fail("key_denied");
        return;
      }
      const auto target = object("target");
      const std::string scriptArgs =
          target ? "{\"target\":" + JsonOf(*target) + "}" : "{}";
      if (!claim(tab->id))
        return;
      const bool printable = !text.empty() && text != "\r";
      const std::wstring common =
          L",\"modifiers\":" + std::to_wstring(mods) + L",\"key\":" +
          preview::Wide(JsonQuote(info.name ? info.name : key)) +
          L",\"code\":" + preview::Wide(JsonQuote(info.code)) +
          L",\"windowsVirtualKeyCode\":" + std::to_wstring(info.vk) +
          L",\"nativeVirtualKeyCode\":" + std::to_wstring(info.vk);
      const std::wstring down =
          std::wstring(L"{\"type\":") +
          (text.empty() ? L"\"rawKeyDown\"" : L"\"keyDown\"") + common +
          (text.empty() ? std::wstring()
                        : L",\"text\":" + preview::Wide(JsonQuote(text))) +
          command + L"}";
      const std::wstring up = L"{\"type\":\"keyUp\"" + common + L"}";
      AgentScript(
          id, tab, "keyprep", scriptArgs,
          [this, id, key, mods, printable, down,
           up](const std::shared_ptr<Tab> &t, const preview::Value &focus) {
            const auto secret = focus.object.find("sensitive");
            if (printable && secret != focus.object.end() &&
                secret->second.type == preview::Value::Boolean &&
                secret->second.number == 1) {
              FinishAgent(id, "sensitive_field_denied");
              return;
            }
            auto steps = std::make_shared<std::vector<InputStep>>();
            steps->push_back({L"Input.dispatchKeyEvent", down});
            steps->push_back({L"Input.dispatchKeyEvent", up});
            const std::string prefix = "\"pressed\":" + JsonQuote(key) +
                                       ",\"modifiers\":" + std::to_string(mods);
            AgentInput(id, t, steps, 0,
                       [this, id, prefix](const std::shared_ptr<Tab> &t2) {
                         AgentAfter(id, t2, prefix);
                       });
          });
      return;
    }
    // T6: browser_console y browser_network leen el registro acotado de la
    // pestaña (lo ya ocurrido); no tocan la página ni necesitan que cargue.
    if (tool == "browser_console" || tool == "browser_network") {
      if (!hasArgs || !preview::Text(args->second, "tab_id", 256)) {
        fail("invalid_arguments");
        return;
      }
      const auto tab = AgentTab(args->second.object.at("tab_id").string);
      if (!tab) {
        fail("tab_not_found");
        return;
      }
      uint64_t after = 0;
      if (!browser_agent::ParseCursor(field(args->second, "cursor", 256),
                                      after)) {
        fail("invalid_arguments");
        return;
      }
      const size_t limit =
          preview::Number(args->second, "limit", 1, 100)
              ? static_cast<size_t>(args->second.object.at("limit").number)
              : 50;
      std::string result;
      if (tool == "browser_console") {
        // Sin Runtime.enable (aún sin respuesta o fallido) la consola no se
        // registra: no se finge vacía; el modelo puede reintentar.
        if (!tab->consoleReady) {
          fail("host_unavailable");
          return;
        }
        std::set<std::string> levels;
        const auto list = args->second.object.find("levels");
        if (list != args->second.object.end() &&
            list->second.type == preview::Value::Array)
          for (const auto &level : list->second.array)
            if (level.type == preview::Value::String)
              levels.insert(level.string);
        result = browser_agent::ConsoleJson(tab->console, after, levels, limit);
      } else {
        result = browser_agent::NetworkJson(
            tab->network, after, field(args->second, "url_filter", 256), limit);
      }
      if (claim(tab->id))
        AgentOk(id, result);
      return;
    }
    if (tool == "browser_wait") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const std::string condition = field(args->second, "condition", 16);
      const auto target = object("target");
      const std::string expected = field(args->second, "expected", 4096);
      const bool timed = condition == "time";
      if (condition.empty() ||
          (timed && !preview::Number(args->second, "duration_ms", 1, 30000))) {
        fail("invalid_arguments");
        return;
      }
      std::string base = "{\"condition\":" + JsonQuote(condition);
      if (target)
        base += ",\"target\":" + JsonOf(*target);
      if (!expected.empty())
        base += ",\"expected\":" + JsonQuote(expected);
      const ULONGLONG until =
          timed ? GetTickCount64() +
                      static_cast<ULONGLONG>(
                          args->second.object.at("duration_ms").number)
                : 0;
      if (claim(tab->id))
        AgentWait(id, tab, base, until, 0);
      return;
    }
    if (tool == "browser_screenshot") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const std::string scope = field(args->second, "scope", 16);
      const auto target = object("target");
      const auto rect = object("rect");
      if (!preview::Number(args->second, "view_revision", 1,
                           9007199254740991.0) ||
          (scope == "ref" && !target) || (scope == "rect" && !rect) ||
          (scope != "viewport" && scope != "ref" && scope != "rect")) {
        fail("invalid_arguments");
        return;
      }
      // Sin carpeta de la orden no hay dónde dejar la evidencia.
      if (fixtureRoot.empty()) {
        fail("evidence_unavailable");
        return;
      }
      const double revision = args->second.object.at("view_revision").number;
      if (!claim(tab->id))
        return;
      if (scope == "viewport") {
        AgentScript(id, tab, "state", "{\"ms\":0}",
                    [this, id, revision](const std::shared_ptr<Tab> &t,
                                         const preview::Value &state) {
                      if (!preview::Number(state, "view_revision", revision,
                                           revision)) {
                        FinishAgent(id, "stale_view");
                        return;
                      }
                      AgentShot(id, t, L"", revision);
                    });
        return;
      }
      const std::string prep =
          scope == "ref"
              ? "{\"target\":" + JsonOf(*target) + "}"
              : "{\"rect\":" + JsonOf(*rect) + ",\"view_revision\":" +
                    JsonOf(args->second.object.at("view_revision")) + "}";
      AgentScript(
          id, tab, "shotprep", prep,
          [this, id](const std::shared_ptr<Tab> &t, const preview::Value &box) {
            for (const char *key : {"x", "y", "width", "height"})
              if (!preview::Number(box, key, 0, 1e6)) {
                FinishAgent(id, "protocol_error");
                return;
              }
            if (!preview::Number(box, "view_revision", 1, 9007199254740991.0)) {
              FinishAgent(id, "protocol_error");
              return;
            }
            AgentShot(id, t,
                      L",\"clip\":{\"x\":" + Num(box.object.at("x").number) +
                          L",\"y\":" + Num(box.object.at("y").number) +
                          L",\"width\":" + Num(box.object.at("width").number) +
                          L",\"height\":" +
                          Num(box.object.at("height").number) +
                          L",\"scale\":1}",
                      box.object.at("view_revision").number);
          });
      return;
    }
    if (tool == "browser_zoom") {
      const auto tab = pageTab();
      if (!tab)
        return;
      if (!preview::Number(args->second, "factor", 0.5, 2)) {
        fail("invalid_arguments");
        return;
      }
      if (!tab->controller) {
        fail("host_unavailable");
        return;
      }
      if (!claim(tab->id))
        return;
      const double factor = args->second.object.at("factor").number;
      if (FAILED(tab->controller->put_ZoomFactor(factor))) {
        FinishAgent(id, "host_unavailable");
        return;
      }
      AgentAfter(id, tab,
                 "\"zoom\":" + JsonOf(args->second.object.at("factor")));
      return;
    }
    if (tool == "browser_viewport") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const bool custom = args->second.object.count("width") != 0;
      const auto integer = [&](const char *key) {
        return preview::Number(args->second, key, 0, 100000)
                   ? static_cast<int>(args->second.object.at(key).number)
                   : 0;
      };
      const auto mobile = args->second.object.find("mobile");
      browser_agent::Viewport viewport;
      if (!browser_agent::ViewportFor(
              field(args->second, "preset", 16), custom, integer("width"),
              integer("height"),
              preview::Number(args->second, "dpr", 1, 3)
                  ? args->second.object.at("dpr").number
                  : 0,
              mobile != args->second.object.end() &&
                  mobile->second.type == preview::Value::Boolean &&
                  mobile->second.number == 1,
              field(args->second, "orientation", 16), viewport)) {
        fail("invalid_arguments");
        return;
      }
      if (!claim(tab->id))
        return;
      const std::string prefix =
          viewport.clear
              ? std::string("\"viewport\":\"desktop\"")
              : "\"viewport\":{\"width\":" + std::to_string(viewport.width) +
                    ",\"height\":" + std::to_string(viewport.height) +
                    ",\"mobile\":" + Flag(viewport.mobile) + "}";
      AgentCdp(id, tab,
               viewport.clear ? L"Emulation.clearDeviceMetricsOverride"
                              : L"Emulation.setDeviceMetricsOverride",
               preview::Wide(browser_agent::ViewportParams(viewport)),
               [this, id, prefix](const std::shared_ptr<Tab> &t,
                                  const preview::Value &) {
                 AgentAfter(id, t, prefix);
               });
      return;
    }
    if (tool == "browser_color_scheme") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const std::string mode = field(args->second, "mode", 16);
      std::string params;
      if (!browser_agent::ColorSchemeParams(mode, params)) {
        fail("invalid_arguments");
        return;
      }
      if (!claim(tab->id))
        return;
      AgentCdp(id, tab, L"Emulation.setEmulatedMedia", preview::Wide(params),
               [this, id, mode](const std::shared_ptr<Tab> &t,
                                const preview::Value &) {
                 AgentAfter(id, t, "\"color_scheme\":" + JsonQuote(mode));
               });
      return;
    }
    if (tool == "browser_hover") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const auto target = object("target");
      if (!target) {
        fail("invalid_arguments");
        return;
      }
      const int ms =
          preview::Number(args->second, "duration_ms", 0, 2000)
              ? static_cast<int>(args->second.object.at("duration_ms").number)
              : 60;
      if (!claim(tab->id))
        return;
      AgentScript(
          id, tab, "point", "{\"target\":" + JsonOf(*target) + "}",
          [this, id, ms, field](const std::shared_ptr<Tab> &t,
                                const preview::Value &at) {
            double x = 0, y = 0;
            if (!PointOf(at, x, y)) {
              FinishAgent(id, "protocol_error");
              return;
            }
            auto steps = std::make_shared<std::vector<InputStep>>();
            steps->push_back({L"Input.dispatchMouseEvent",
                              MouseAt(L"mouseMoved", x, y, L"none", 0)});
            const std::string prefix =
                "\"hovered\":true,\"element\":{\"role\":" +
                JsonQuote(field(at, "role", 64)) +
                ",\"name\":" + JsonQuote(field(at, "name", 512)) +
                "},\"x\":" + JsonOf(at.object.at("x")) +
                ",\"y\":" + JsonOf(at.object.at("y"));
            AgentInput(id, t, steps, 0,
                       [this, id, prefix, ms](const std::shared_ptr<Tab> &t2) {
                         AgentAfter(id, t2, prefix,
                                    "{\"ms\":" + std::to_string(ms) + "}");
                       });
          });
      return;
    }
    if (tool == "browser_drag") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const auto from = object("from");
      const auto to = object("to");
      if (!from || !to) {
        fail("invalid_arguments");
        return;
      }
      const int count =
          preview::Number(args->second, "steps", 2, 60)
              ? static_cast<int>(args->second.object.at("steps").number)
              : 10;
      const std::string fromArgs = "{\"target\":" + JsonOf(*from) + "}";
      const std::string toArgs = "{\"target\":" + JsonOf(*to) + "}";
      if (!claim(tab->id))
        return;
      // Resolver un extremo puede desplazar la vista: si las dos revisiones
      // no coinciden se vuelve a resolver el origen una vez.
      const auto revision = [](const preview::Value &at) {
        return preview::Number(at, "view_revision", 1, 9007199254740991.0)
                   ? at.object.at("view_revision").number
                   : -1.0;
      };
      AgentScript(
          id, tab, "point", fromArgs,
          [this, id, toArgs, fromArgs, count,
           revision](const std::shared_ptr<Tab> &t, const preview::Value &a) {
            AgentScript(
                id, t, "point", toArgs,
                [this, id, fromArgs, count, revision,
                 a](const std::shared_ptr<Tab> &t2, const preview::Value &b) {
                  double fx = 0, fy = 0, tx = 0, ty = 0;
                  if (!PointOf(a, fx, fy) || !PointOf(b, tx, ty)) {
                    FinishAgent(id, "protocol_error");
                    return;
                  }
                  if (revision(a) == revision(b)) {
                    AgentDragGo(id, t2, fx, fy, tx, ty, count);
                    return;
                  }
                  AgentScript(id, t2, "point", fromArgs,
                              [this, id, count, revision, b, tx,
                               ty](const std::shared_ptr<Tab> &t3,
                                   const preview::Value &again) {
                                double gx = 0, gy = 0;
                                if (!PointOf(again, gx, gy)) {
                                  FinishAgent(id, "protocol_error");
                                  return;
                                }
                                if (revision(again) != revision(b)) {
                                  FinishAgent(id, "stale_view");
                                  return;
                                }
                                AgentDragGo(id, t3, gx, gy, tx, ty, count);
                              });
                });
          });
      return;
    }
    if (tool == "browser_fill_form") {
      const auto tab = pageTab();
      if (!tab)
        return;
      const auto list = args->second.object.find("fields");
      if (list == args->second.object.end() ||
          list->second.type != preview::Value::Array ||
          list->second.array.empty() || list->second.array.size() > 32) {
        fail("invalid_arguments");
        return;
      }
      for (const auto &f : list->second.array) {
        const bool known =
            f.type == preview::Value::Object && preview::Text(f, "kind", 16) &&
            f.object.count("target") &&
            f.object.at("target").type == preview::Value::Object &&
            f.object.count("value");
        const std::string fieldKind = known ? f.object.at("kind").string : "";
        const auto value =
            known ? f.object.at("value").type : preview::Value::Null;
        if (!((fieldKind == "text" && value == preview::Value::String) ||
              ((fieldKind == "checkbox" || fieldKind == "radio") &&
               value == preview::Value::Boolean) ||
              (fieldKind == "select" && value == preview::Value::Object))) {
          fail("invalid_arguments");
          return;
        }
      }
      auto fields = std::make_shared<const std::vector<preview::Value>>(
          list->second.array);
      if (!claim(tab->id))
        return;
      // Todos los campos se comprueban antes de escribir ninguno.
      AgentScript(id, tab, "formcheck",
                  "{\"fields\":" + JsonOf(list->second) + "}",
                  [this, id, fields](const std::shared_ptr<Tab> &t,
                                     const preview::Value &) {
                    AgentFill(id, t, fields, 0, "");
                  });
      return;
    }
    // T6: browser_debug_js solo sobre una pestaña que enseña una página
    // admitida por la política de orígenes (pageTab), en su propio mundo
    // aislado y con el tope de tiempo de browser_tools.zig (2000 ms).
    if (tool == "browser_debug_js") {
      const auto tab = pageTab();
      if (!tab)
        return;
      if (!preview::Text(args->second, "code", 32768)) {
        fail("invalid_arguments");
        return;
      }
      const int timeoutMs =
          preview::Number(args->second, "timeout_ms", 1, 2000)
              ? static_cast<int>(args->second.object.at("timeout_ms").number)
              : 2000;
      if (claim(tab->id))
        AgentDebug(id, tab, args->second.object.at("code").string, timeoutMs,
                   false);
      return;
    }
    if (tool == "browser_tabs" && hasArgs &&
        preview::Text(args->second, "action", 32) &&
        args->second.object.at("action").string != "list") {
      const std::string action = args->second.object.at("action").string;
      const auto listNow = [this, id](const std::string &extra) {
        auto &pending = agentPending.at(id);
        pending.extraTab = extra;
        pending.tabs.clear();
        for (const auto &t : tabs)
          pending.tabs.push_back(t->id);
        pending.active = Active() ? Active()->id : 0;
        AgentTitle(id, 0);
      };
      if (action == "create") {
        // Ocho pestañas por sesión (contrato §2.3).
        if (tabs.size() >= 8) {
          fail("tab_limit");
          return;
        }
        const bool withUrl = preview::Text(args->second, "url", 8192);
        std::wstring target;
        if (withUrl) {
          target = preview::Wide(args->second.object.at("url").string);
          std::wstring mapped;
          const auto local = ProjectUrl(target, mapped);
          if (local == LocalFile::Outside) {
            fail("permission_required");
            return;
          }
          if (local == LocalFile::Mapped)
            target = mapped;
        }
        if (!claim(0))
          return;
        if (!NewTab() || !Active()) {
          FinishAgent(id, "host_unavailable");
          return;
        }
        const auto tab = Active();
        if (!withUrl) {
          listNow(tab->agentId);
          return;
        }
        auto &pending = agentPending.at(id);
        pending.listAfter = true;
        pending.extraTab = tab->agentId;
        pending.active = tab->id;
        pending.navTab = tab->id;
        pending.loadMs = preview::Number(args->second, "timeout_ms", 1, 30000)
                             ? static_cast<ULONGLONG>(
                                   args->second.object.at("timeout_ms").number)
                             : 10000;
        // La pestaña nueva aún se prepara: margen propio antes de la carga.
        pending.loadDeadline = GetTickCount64() + pending.loadMs + 8000;
        tab->agentNav = id;
        GoTab(tab, target);
        return;
      }
      if (action == "close" || action == "select") {
        if (!preview::Text(args->second, "tab_id", 256)) {
          fail("invalid_arguments");
          return;
        }
        const auto tab = AgentTab(args->second.object.at("tab_id").string);
        if (!tab) {
          fail("tab_not_found");
          return;
        }
        const std::string agentId = tab->agentId;
        if (!claim(0))
          return;
        if (action == "select")
          DoSelectTab(tab->id);
        else
          AgentCloseTab(tab);
        listNow(agentId);
        return;
      }
      fail("backend_unsupported");
      return;
    }
    if (request.object.at("tool").string == "browser_navigate") {
      if (args == request.object.end() ||
          !preview::Text(args->second, "action", 16) ||
          !preview::Text(args->second, "tab_id", 256)) {
        fail("invalid_arguments");
        return;
      }
      const std::string action = args->second.object.at("action").string;
      if (action == "back" || action == "forward" || action == "reload" ||
          action == "stop") {
        const auto tab = AgentTab(args->second.object.at("tab_id").string);
        if (!tab) {
          fail("tab_not_found");
          return;
        }
        // Una pestaña en blanco no tiene página que recargar ni historial
        // (about:blank no avisa del fin de la carga).
        if (!tab->view || !tab->ready || Blank(tab->url)) {
          fail("host_unavailable");
          return;
        }
        BOOL can = FALSE;
        if (action == "back")
          tab->view->get_CanGoBack(&can);
        else if (action == "forward")
          tab->view->get_CanGoForward(&can);
        if ((action == "back" || action == "forward") && !can) {
          fail("no_history");
          return;
        }
        if (!tab->agentNav.empty() && !agentPending.count(tab->agentNav))
          tab->agentNav.clear();
        if (!tab->agentNav.empty() && action != "stop") {
          fail("busy");
          return;
        }
        if (!claim(tab->id))
          return;
        if (action == "stop") {
          // Detiene la carga; lo que el agente tuviera navegando en esta
          // pestaña termina como ocupado y esta petición devuelve la URL.
          if (!tab->agentNav.empty())
            FinishAgent(tab->agentNav, "busy");
          tab->view->Stop();
          tab->loading = false;
          tab->agentNav = id;
          AgentNavOk(tab);
          Refresh();
          return;
        }
        auto &pending = agentPending.at(id);
        pending.navTab = tab->id;
        pending.loadMs = preview::Number(args->second, "timeout_ms", 1, 30000)
                             ? static_cast<ULONGLONG>(
                                   args->second.object.at("timeout_ms").number)
                             : 10000;
        pending.started = GetTickCount64();
        pending.loadDeadline = pending.started + pending.loadMs;
        // Atrás/adelante dentro del mismo documento no emite
        // NavigationCompleted: el temporizador lo da por hecho (1,5 s).
        pending.history = action != "reload";
        tab->agentNav = id;
        tab->blocked = false;
        HRESULT hr = S_OK;
        if (action == "back")
          hr = tab->view->GoBack();
        else if (action == "forward")
          hr = tab->view->GoForward();
        else {
          tab->hasError = false;
          hr = tab->view->Reload();
        }
        if (FAILED(hr)) {
          tab->agentNav.clear();
          FinishAgent(id, "host_unavailable");
        }
        Refresh();
        return;
      }
      if (args->second.object.at("action").string != "url" ||
          !preview::Text(args->second, "url", 8192)) {
        fail(args->second.object.at("action").string != "url"
                 ? "backend_unsupported"
                 : "invalid_arguments");
        return;
      }
      const std::string &wanted = args->second.object.at("tab_id").string;
      std::shared_ptr<Tab> tab;
      for (const auto &t : tabs)
        if (t->agentId == wanted && !t->closed)
          tab = t;
      if (!tab) {
        fail("tab_not_found");
        return;
      }
      // Una pestaña que aún se prepara (sesión recién abierta) guarda la
      // dirección en `pending` y navega a ella al quedar lista.
      // Una navegación anterior que ya terminó por plazo deja su id en la
      // pestaña: solo cuenta como ocupada si sigue pendiente de verdad.
      if (!tab->agentNav.empty() && !agentPending.count(tab->agentNav))
        tab->agentNav.clear();
      if (!tab->agentNav.empty()) {
        fail("busy");
        return;
      }
      if (agentPending.count(id)) {
        fail("protocol_error");
        return;
      }
      if (agentPending.size() >= 32) {
        fail("busy");
        return;
      }
      // Un archivo del proyecto (file:///…, ruta absoluta o relativa) se abre
      // por el origen local controlado; uno de fuera no se abre.
      std::wstring target = preview::Wide(args->second.object.at("url").string);
      std::wstring mapped;
      const auto local = ProjectUrl(target, mapped);
      if (local == LocalFile::Outside) {
        fail("permission_required");
        return;
      }
      if (local == LocalFile::Mapped)
        target = mapped;
      AgentPending pending;
      pending.done = std::move(done);
      pending.epoch = controlEpoch;
      pending.deadline = deadline;
      pending.active = tab->id;
      pending.navTab = tab->id;
      // El motor suma al plazo de la petición la espera de la aprobación
      // humana; la carga en sí conserva el plazo que pidió el modelo.
      pending.loadMs = preview::Number(args->second, "timeout_ms", 1, 30000)
                           ? static_cast<ULONGLONG>(
                                 args->second.object.at("timeout_ms").number)
                           : 10000;
      pending.loadDeadline = GetTickCount64() + pending.loadMs;
      agentPending.emplace(id, std::move(pending));
      tab->agentNav = id;
      GoTab(tab, target);
      return;
    }
    if (request.object.at("tool").string == "browser_text") {
      if (args == request.object.end() ||
          !preview::Text(args->second, "scope", 16) ||
          !preview::Text(args->second, "tab_id", 256)) {
        fail("invalid_arguments");
        return;
      }
      if (args->second.object.at("scope").string != "page") {
        fail("backend_unsupported");
        return;
      }
      const std::string &wanted = args->second.object.at("tab_id").string;
      std::shared_ptr<Tab> tab;
      for (const auto &t : tabs)
        if (t->agentId == wanted && !t->closed)
          tab = t;
      if (!tab) {
        fail("tab_not_found");
        return;
      }
      if (!tab->view || !tab->ready || tab->blocked) {
        fail("host_unavailable");
        return;
      }
      if (agentPending.count(id)) {
        fail("protocol_error");
        return;
      }
      if (agentPending.size() >= 32) {
        fail("busy");
        return;
      }
      AgentPending pending;
      pending.done = std::move(done);
      pending.epoch = controlEpoch;
      pending.deadline = deadline;
      pending.active = tab->id;
      agentPending.emplace(id, std::move(pending));
      AgentText(id, tab);
      return;
    }
    if (request.object.at("tool").string != "browser_tabs" ||
        args == request.object.end() ||
        !preview::Text(args->second, "action", 32) ||
        args->second.object.at("action").string != "list") {
      fail("backend_unsupported");
      return;
    }
    if (agentPending.count(id)) {
      fail("protocol_error");
      return;
    }
    if (agentPending.size() >= 32) {
      fail("busy");
      return;
    }
    AgentPending pending;
    pending.done = std::move(done);
    pending.epoch = controlEpoch;
    pending.deadline = deadline;
    pending.active = Active() ? Active()->id : 0;
    for (const auto &t : tabs)
      pending.tabs.push_back(t->id);
    agentPending.emplace(id, std::move(pending));
    AgentTitle(id, 0);
  }
  void SetStatus(const std::wstring &text, bool isError) {
    status = text;
    statusError = isError;
    if (hwnd && GetDlgItem(hwnd, Status))
      SetWindowTextW(GetDlgItem(hwnd, Status), text.c_str());
    Publish();
  }
  void Error(const std::wstring &s, HRESULT hr = S_OK) {
    if (!alive)
      return;
    std::wstring message = s;
    if (FAILED(hr))
      message +=
          L" (HRESULT " + std::to_wstring(static_cast<unsigned>(hr)) + L")";
    // Diagnostics do not contain destinations, response headers or page text.
    std::fprintf(stderr, "[BrowserPanel] %s hr=%08lx\n",
                 preview::Narrow(s).c_str(), static_cast<unsigned long>(hr));
    SetStatus(message, true);
  }
  bool Check(HRESULT hr, const wchar_t *operation) {
    if (SUCCEEDED(hr))
      return true;
    Error(operation, hr);
    return false;
  }
  static std::wstring NewId() {
    GUID guid{};
    wchar_t text[40]{};
    if (FAILED(CoCreateGuid(&guid)) || !StringFromGUID2(guid, text, 40))
      return L"";
    std::wstring id;
    for (const wchar_t *c = text; *c; ++c)
      if ((*c >= L'0' && *c <= L'9') || (*c >= L'a' && *c <= L'f') ||
          (*c >= L'A' && *c <= L'F'))
        id += *c;
    return id;
  }
  // A destination the policy does not cover: the tab keeps its previous page
  // hidden behind a state card that explains why and offers to approve.
  // Cierra la navegación pendiente del agente en esta pestaña: con éxito si
  // cargó, permission_required si la política la bloqueó, host_unavailable si
  // la carga falló. Una cancelación sin bloqueo (aprobación en curso) sigue
  // esperando hasta su plazo.
  // ¿Hay una aprobación de origen pendiente por la que espera esta pestaña?
  bool Awaiting(unsigned tab) const {
    for (const auto &a : approvals)
      for (const auto &w : a.waiters)
        if (w.tab == tab)
          return true;
    return false;
  }
  void FinishAgentNavigation(const std::shared_ptr<Tab> &t, bool loaded) {
    if (!t || t->agentNav.empty())
      return;
    const std::string id = t->agentNav;
    auto pending = agentPending.find(id);
    if (pending == agentPending.end()) {
      t->agentNav.clear();
      return;
    }
    if (t->blocked) {
      // 12-nov: mientras el usuario decide en el diálogo, la petición del
      // agente ESPERA (antes moría aquí con permission_required aunque el
      // usuario aprobara un segundo después). Se resuelve en DoResolve/Deny
      // o al vencer su plazo.
      if (Awaiting(t->id))
        return;
      t->agentNav.clear();
      FinishAgent(id, "permission_required");
      return;
    }
    if (t->hasError) {
      t->agentNav.clear();
      FinishAgent(id, "host_unavailable");
      return;
    }
    if (!loaded)
      return;
    AgentNavOk(t);
  }
  // Marca la pestaña como bloqueada sin cerrar la navegación del agente: lo
  // usa Admission antes de preguntar al usuario.
  static void Mark(const std::shared_ptr<Tab> &t, const std::wstring &url,
                   const std::wstring &why) {
    if (!t)
      return;
    t->blocked = true;
    t->blockedUrl = url;
    t->blockedReason = why;
    t->loading = false;
  }
  void Block(const std::shared_ptr<Tab> &t, const std::wstring &url,
             const std::wstring &why) {
    if (!t)
      return;
    Mark(t, url, why);
    FinishAgentNavigation(t, false);
    Refresh();
  }
  // Rearma el plazo de carga de la navegación del agente en esta pestaña
  // (la espera de la aprobación humana no consume el plazo de la carga).
  void RearmAgentLoad(const std::shared_ptr<Tab> &t) {
    if (!t || t->agentNav.empty())
      return;
    const auto pending = agentPending.find(t->agentNav);
    if (pending != agentPending.end() && pending->second.loadMs)
      pending->second.loadDeadline = GetTickCount64() + pending->second.loadMs;
  }
  static constexpr const wchar_t *NotApproved =
      L"Origen no aprobado. El panel solo abre la página de la orden, apps "
      L"de localhost registradas y sitios que apruebes.";
  void GoTab(const std::shared_ptr<Tab> &t, const std::wstring &url) {
    t->pending = url;
    t->blocked = false;
    t->hasError = false;
    if (t->ready && t->view)
      Check(t->view->Navigate(url.c_str()), L"Abrir página");
    Refresh();
  }
  // Full-window fallback only: that window has no WebUI to ask.
  bool ApproveSync(const std::wstring &origin, const std::wstring &url) {
    const auto text =
        L"¿Permitir que el panel de navegador abra este origen?\n\n" + origin +
        L"\n\nSe recordará en el perfil propio de DevAgents. No comparte "
        L"sesiones con tu navegador personal.";
    if (themed::Show(parent, L"Aprobar destino del navegador", text,
                     themed::Kind::question, themed::Buttons::yes_no, true,
                     L"Permitir", L"No permitir") != IDYES)
      return false;
    if (!policy.Approve(url, ledger)) {
      Error(L"No se pudo guardar la aprobación; destino bloqueado");
      return false;
    }
    return true;
  }
  void Deny(size_t index, const std::wstring &why) {
    const Approval a = approvals[index];
    approvals.erase(approvals.begin() + static_cast<std::ptrdiff_t>(index));
    denied[a.origin] = GetTickCount64();
    for (const auto &w : a.waiters)
      if (auto t = Find(w.tab)) {
        t->blocked = true;
        t->blockedReason = why;
        FinishAgentNavigation(t, false);
      }
    Refresh();
  }
  void DenyAll(const std::wstring &why) {
    while (!approvals.empty())
      Deny(approvals.size() - 1, why);
  }
  void Sweep() {
    const auto now = GetTickCount64();
    for (size_t i = approvals.size(); i-- > 0;)
      if (now - approvals[i].at > ApprovalTimeoutMs)
        Deny(i, L"Sin respuesta: destino rechazado.");
  }
  // Decides whether `url` may be opened now. When it may not and an approval
  // could change that, the trusted UI is asked; the navigation stays blocked
  // until a click arrives. No WebUI, or losing it, means "No".
  // `owner` binds a wait to the tab that asked when there is no tab to block
  // (a pop-up): closing that tab drops the wait.
  Admit Admission(const std::shared_ptr<Tab> &t, const std::wstring &url,
                  const char *source, std::function<void()> resume,
                  unsigned owner = 0) {
    if (CanOpen(url))
      return Admit::Go;
    const auto origin = browser::Policy::Origin(url);
    if (origin.empty() || origin == L"https://preview.local:443") {
      reason = "El destino no es un origen http(s) permitido";
      Block(t, url, L"Destino no permitido por la política del navegador.");
      return Admit::Refused;
    }
    if (full) {
      if (ApproveSync(origin, url))
        return Admit::Go;
      reason = "Destino rechazado";
      Block(t, url, L"Destino rechazado.");
      return Admit::Refused;
    }
    for (auto &a : approvals)
      if (a.origin == origin) {
        // Same exact origin already asked: join that request, no second dialog.
        if (a.waiters.size() >= MaxWaiters) {
          reason = "Demasiadas navegaciones esperando este origen";
          Block(t, url,
                L"Demasiadas navegaciones esperan la aprobación de este "
                L"origen; responde al diálogo.");
          return Admit::Refused;
        }
        Mark(t, url, NotApproved);
        a.waiters.push_back({t ? t->id : owner, std::move(resume)});
        Refresh();
        return Admit::Asked;
      }
    const bool byUser = std::strcmp(source, "address") == 0;
    const auto recent = denied.find(origin);
    if (!byUser && (approvals.size() >= MaxApprovals ||
                    (recent != denied.end() &&
                     GetTickCount64() - recent->second < DeniedQuietMs))) {
      reason = "Destino bloqueado sin preguntar de nuevo";
      Block(t, url, NotApproved);
      return Admit::Refused;
    }
    const auto id = NewId();
    if (id.empty() || approvals.size() >= MaxApprovals) {
      reason = "No se pudo pedir la aprobación";
      Block(t, url, NotApproved);
      return Admit::Refused;
    }
    // La pestaña queda bloqueada, pero la navegación del agente que la pidió
    // sigue viva hasta que el usuario responda (o venza su plazo).
    Mark(t, url, NotApproved);
    Approval a;
    a.id = preview::Narrow(id);
    a.origin = origin;
    a.source = source;
    a.at = GetTickCount64();
    a.waiters.push_back({t ? t->id : owner, std::move(resume)});
    approvals.push_back(std::move(a));
    if (!Publish()) {
      approvals.pop_back();
      reason = "La interfaz de confianza no está disponible; destino rechazado";
      Block(t, url,
            L"La interfaz de confianza no está disponible; destino "
            L"rechazado.");
      return Admit::Refused;
    }
    Refresh();
    return Admit::Asked;
  }
  std::wstring Allowlist() const {
    auto list = policy.ConnectionAllowlist();
    if (!fixtureRoot.empty())
      list.insert(1, L"\"https://preview.local/*\" ");
    return list;
  }
  void Layout() {
    if (!hwnd)
      return;
    RECT r{};
    GetClientRect(hwnd, &r);
    if (!full) {
      // The trusted bar sits above this window; the page owns all of it.
      for (auto &t : tabs)
        if (t->controller && !t->closed)
          Check(t->controller->put_Bounds(r), L"Redimensionar navegador");
      return;
    }
    const UINT dpi = GetDpiForWindow(hwnd);
    const int unit = std::max(24, MulDiv(28, dpi ? dpi : 96, 96));
    const int w = std::max(0, static_cast<int>(r.right));
    const int pad =
        std::min(MulDiv(4, dpi ? dpi : 96, 96), std::max(0, (w - 1) / 2));
    const int gap = std::max(1, MulDiv(2, dpi ? dpi : 96, 96));
    const int available = std::max(0, w - 2 * pad);
    const int fieldMin = MulDiv(80, dpi ? dpi : 96, 96);
    const bool wide = available >= fieldMin + 5 * unit + 4 * gap;
    int x = pad, y = pad;
    auto nextRow = [&] {
      x = pad;
      y += unit + gap;
    };
    auto place = [&](int id, int preferred) {
      const int width = std::min(available, preferred);
      if (x != pad && x + width > w - pad)
        nextRow();
      // A combo's requested height includes its drop-down list; the closed
      // native control still occupies one row, as do the other controls.
      MoveWindow(GetDlgItem(hwnd, id), x, y, width,
                 id == Tabs ? unit * 8 : unit, TRUE);
      x += width + gap;
    };
    // Narrow panels keep the selector and address on their own rows.
    // Buttons wrap further when even their group cannot fit at this DPI.
    place(Tabs, wide ? available - 5 * unit - 4 * gap : available);
    if (!wide)
      nextRow();
    place(Register, 2 * unit);
    place(Add, unit);
    place(Remove, unit);
    place(HideControl, unit);
    nextRow();
    for (int id = IdBack; id <= IdReload; ++id)
      place(id, unit);
    if (wide) {
      place(Address, available - 5 * unit - 4 * gap);
      place(Go, 2 * unit);
    } else {
      place(Go, 2 * unit);
      nextRow();
      place(Address, available);
    }
    const int contentTop = y + unit + pad;
    const int statusTop =
        std::max(contentTop, static_cast<int>(r.bottom) - unit);
    MoveWindow(GetDlgItem(hwnd, Status), pad, statusTop, available,
               std::max(0, static_cast<int>(r.bottom) - statusTop), TRUE);
    RECT bounds{0, contentTop, r.right, statusTop};
    for (auto &t : tabs)
      if (t->controller && !t->closed)
        Check(t->controller->put_Bounds(bounds), L"Redimensionar navegador");
  }
  // Whether the page itself is on screen. Otherwise the area belongs to a
  // WebUI state card (blank tab, load error, blocked destination, approval).
  // La pestaña activa tiene una página que enseñar (aunque ahora mismo la
  // tape una capa de la cabina).
  bool PageReady() const {
    if (full)
      return true;
    const auto t = Active();
    return open && t && t->controller && !t->closed && t->ready &&
           !t->hasError && !t->blocked && !Blank(t->url) && approvals.empty();
  }
  bool ShowsPage() const { return full || (PageReady() && !covered); }
  // 12-nov: la página es una ventana nativa SIEMPRE por encima del HTML de la
  // cabina, así que tapaba la bandeja de avisos, los menús, la paleta y los
  // modales. Cuando la cabina avisa de que una capa suya pisa el área de la
  // página, el host captura la página, se la entrega como imagen fija
  // (`browser.cover`) y oculta la ventana nativa; al retirarse la capa, la
  // vuelve a mostrar. La página sigue viva debajo (no se marca invisible).
  bool covered = false, coverWanted = false;
  bool DoCover(bool on) {
    reason.clear();
    if (full || !hwnd) {
      reason = "El navegador no está abierto en la cabina";
      return false;
    }
    coverWanted = on;
    if (!on) {
      if (covered) {
        covered = false;
        Refresh();
      }
      return true;
    }
    if (covered)
      return true;
    const auto t = Active();
    if (!PageReady() || !t || !t->view) {
      covered = true;
      Refresh();
      return true;
    }
    auto weak = weak_from_this();
    auto *callback =
        new Handler<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
                    HRESULT, LPCWSTR>(
            IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
            [weak](HRESULT hr, LPCWSTR json) {
              auto s = weak.lock();
              if (!s || !s->alive || !s->coverWanted || s->covered)
                return S_OK;
              // {"data":"<base64>"}: el base64 no lleva comillas ni escapes.
              constexpr size_t kMax = 12u * 1024u * 1024u;
              if (SUCCEEDED(hr) && json && s->sink) {
                const std::wstring raw(json, wcsnlen_s(json, kMax));
                const std::wstring key = L"\"data\":\"";
                const auto from = raw.find(key);
                const auto to = from == std::wstring::npos
                                    ? std::wstring::npos
                                    : raw.find(L'"', from + key.size());
                if (to != std::wstring::npos && raw.size() < kMax)
                  s->sink(
                      L"{\"push\":\"browser.cover\",\"payload\":{\"image\":"
                      L"\"data:image/jpeg;base64," +
                      raw.substr(from + key.size(), to - from - key.size()) +
                      L"\"}}");
              }
              // Con o sin imagen, la capa de la cabina debe verse.
              s->covered = true;
              s->Refresh();
              return S_OK;
            });
    // Operación fija del host: ni método ni parámetros vienen de fuera.
    const HRESULT hr = t->view->CallDevToolsProtocolMethod(
        L"Page.captureScreenshot",
        LR"cdp({"format":"jpeg","quality":82,"captureBeyondViewport":false})cdp",
        callback);
    callback->Release();
    if (FAILED(hr)) {
      covered = true;
      Refresh();
    }
    return true;
  }
  void Refresh() {
    if (!alive)
      return;
    HookPageInput();
    for (auto &t : tabs) {
      if (!t->view || t->closed)
        continue;
      LPWSTR source = nullptr;
      BOOL canBack = FALSE, canForward = FALSE;
      if (SUCCEEDED(t->view->get_Source(&source)) && source) {
        const std::wstring now = source;
        t->url = now == GuardUrl ? (Blank(t->pending) ? L"" : t->pending) : now;
        CoTaskMemFree(source);
      }
      t->view->get_CanGoBack(&canBack);
      t->view->get_CanGoForward(&canForward);
      t->canBack = canBack;
      t->canForward = canForward;
    }
    const bool shows = ShowsPage();
    // Tapada por una capa de la cabina, la página sigue «visible» para su
    // motor (no se pausa ni cambia visibilityState): solo se oculta el HWND.
    const bool live = shows || (covered && PageReady());
    if (!full && hwnd)
      ShowWindow(hwnd, shows ? SW_SHOWNA : SW_HIDE);
    for (size_t i = 0; i < tabs.size(); ++i)
      if (tabs[i]->controller && !tabs[i]->closed)
        Check(tabs[i]->controller->put_IsVisible(i == active && live ? TRUE
                                                                     : FALSE),
              L"Elegir pestaña");
    if (full && hwnd) {
      SendDlgItemMessageW(hwnd, Tabs, CB_RESETCONTENT, 0, 0);
      for (size_t i = 0; i < tabs.size(); ++i) {
        auto label = std::to_wstring(i + 1) + L" · " + tabs[i]->title;
        SendDlgItemMessageW(hwnd, Tabs, CB_ADDSTRING, 0,
                            reinterpret_cast<LPARAM>(label.c_str()));
      }
      SendDlgItemMessageW(hwnd, Tabs, CB_SETCURSEL, active, 0);
      if (const auto t = Active()) {
        SetWindowTextW(GetDlgItem(hwnd, Address), t->url.c_str());
        EnableWindow(GetDlgItem(hwnd, IdBack), t->canBack);
        EnableWindow(GetDlgItem(hwnd, IdForward), t->canForward);
      }
    }
    Layout();
    Publish();
  }
  // T6: texto legible de un argumento de console.* (RemoteObject).
  static std::string RemoteText(const preview::Value &arg) {
    if (arg.type != preview::Value::Object)
      return "?";
    const auto value = arg.object.find("value");
    if (value != arg.object.end()) {
      switch (value->second.type) {
      case preview::Value::String:
        return value->second.string;
      case preview::Value::Number: {
        char text[40];
        std::snprintf(text, sizeof text, "%.15g", value->second.number);
        return text;
      }
      case preview::Value::Boolean:
        return value->second.number == 1 ? "true" : "false";
      case preview::Value::Null:
        return "null";
      default:
        break;
      }
    }
    for (const char *key : {"unserializableValue", "description", "type"})
      if (preview::Text(arg, key, 4096))
        return arg.object.at(key).string;
    return "?";
  }
  // T6: anota un evento CDP en el registro acotado de la pestaña. Un evento
  // ilegible deja constancia en vez de desaparecer.
  static void AgentLog(Tab &t, const std::wstring &event,
                       const std::string &raw) {
    namespace ba = browser_agent;
    preview::Value v;
    const bool parsed =
        !raw.empty() &&
        preview::Parser(raw, true, true, 8u * 1024u * 1024u, 32, 512, 1024)
            .Parse(v) &&
        v.type == preview::Value::Object;
    const auto number = [](const preview::Value &o, const char *key) {
      return preview::Number(o, key, 0, 1e9)
                 ? static_cast<int>(o.object.at(key).number)
                 : 0;
    };
    if (event == L"Runtime.consoleAPICalled" ||
        event == L"Runtime.exceptionThrown") {
      ba::ConsoleEntry e;
      e.level = event == L"Runtime.exceptionThrown" ? "error" : "log";
      if (!parsed) {
        e.text = "[mensaje de consola que el host no pudo leer]";
        t.console.Push(std::move(e));
        return;
      }
      std::string text;
      if (event == L"Runtime.consoleAPICalled") {
        e.level = ba::ConsoleLevel(
            preview::Text(v, "type", 32) ? v.object.at("type").string : "log");
        const auto args = v.object.find("args");
        if (args != v.object.end() &&
            args->second.type == preview::Value::Array)
          for (const auto &arg : args->second.array) {
            if (!text.empty())
              text += ' ';
            text += RemoteText(arg);
            if (text.size() > 2000)
              break;
          }
        const auto stack = v.object.find("stackTrace");
        if (stack != v.object.end() &&
            stack->second.type == preview::Value::Object) {
          const auto frames = stack->second.object.find("callFrames");
          if (frames != stack->second.object.end() &&
              frames->second.type == preview::Value::Array &&
              !frames->second.array.empty() &&
              preview::Text(frames->second.array[0], "url", 8192)) {
            e.url = frames->second.array[0].object.at("url").string;
            e.line = number(frames->second.array[0], "lineNumber") + 1;
          }
        }
      } else {
        const auto details = v.object.find("exceptionDetails");
        if (details != v.object.end() &&
            details->second.type == preview::Value::Object) {
          const auto &d = details->second;
          const auto exception = d.object.find("exception");
          text = exception != d.object.end() &&
                         preview::Text(exception->second, "description", 8192)
                     ? exception->second.object.at("description").string
                 : preview::Text(d, "text", 8192) ? d.object.at("text").string
                                                  : "Excepción sin texto";
          if (preview::Text(d, "url", 8192)) {
            e.url = d.object.at("url").string;
            e.line = number(d, "lineNumber") + 1;
          }
        }
      }
      e.text = ba::Clip(text, 2000);
      e.url = ba::RedactUrl(e.url);
      t.console.Push(std::move(e));
      return;
    }
    if (!parsed || !preview::Text(v, "requestId", 256)) {
      ba::NetworkEntry e;
      e.failure = "[evento de red que el host no pudo leer]";
      t.network.Push(std::move(e));
      return;
    }
    const std::string id = v.object.at("requestId").string;
    const auto latest = [&]() -> ba::NetworkEntry * {
      for (auto it = t.network.items.rbegin(); it != t.network.items.rend();
           ++it)
        if (it->requestId == id)
          return &*it;
      return nullptr;
    };
    if (event == L"Network.requestWillBeSent") {
      const auto request = v.object.find("request");
      if (request == v.object.end() ||
          request->second.type != preview::Value::Object)
        return;
      // Una redirección llega como petición nueva con la respuesta anterior.
      const auto redirect = v.object.find("redirectResponse");
      if (redirect != v.object.end())
        if (auto *previous = latest())
          previous->status = number(redirect->second, "status");
      ba::NetworkEntry e;
      e.requestId = id;
      e.method = preview::Text(request->second, "method", 16)
                     ? request->second.object.at("method").string
                     : "?";
      e.url = ba::RedactUrl(preview::Text(request->second, "url", 1u << 20)
                                ? request->second.object.at("url").string
                                : "");
      e.type = preview::Text(v, "type", 32) ? v.object.at("type").string : "";
      t.network.Push(std::move(e));
      return;
    }
    auto *entry = latest();
    if (!entry)
      return;
    if (event == L"Network.responseReceived") {
      const auto response = v.object.find("response");
      if (response != v.object.end())
        entry->status = number(response->second, "status");
      if (preview::Text(v, "type", 32))
        entry->type = v.object.at("type").string;
    } else if (event == L"Network.loadingFailed") {
      entry->failure = preview::Text(v, "blockedReason", 64)
                           ? "blocked:" + v.object.at("blockedReason").string
                       : preview::Text(v, "errorText", 256)
                           ? v.object.at("errorText").string
                           : "failed";
    }
  }
  bool ListenAgentLog(const std::shared_ptr<Tab> &tab, const wchar_t *event) {
    ICoreWebView2DevToolsProtocolEventReceiver *receiver = nullptr;
    if (FAILED(tab->view->GetDevToolsProtocolEventReceiver(event, &receiver)))
      return false;
    std::weak_ptr<Tab> wt = tab;
    const std::wstring name = event;
    auto *handler =
        new Handler<ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
                    ICoreWebView2 *,
                    ICoreWebView2DevToolsProtocolEventReceivedEventArgs *>(
            IID_ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
            [wt, name](ICoreWebView2 *,
                       ICoreWebView2DevToolsProtocolEventReceivedEventArgs *a) {
              auto t = wt.lock();
              LPWSTR json = nullptr;
              const HRESULT hr = a->get_ParameterObjectAsJson(&json);
              if (t && !t->closed)
                AgentLog(*t, name,
                         SUCCEEDED(hr) && json
                             ? preview::Narrow(json, 8u * 1024u * 1024u)
                             : std::string());
              if (json)
                CoTaskMemFree(json);
              return S_OK;
            });
    EventRegistrationToken token{};
    const HRESULT hr =
        receiver->add_DevToolsProtocolEventReceived(handler, &token);
    handler->Release();
    receiver->Release();
    return SUCCEEDED(hr);
  }
  bool Cdp(const std::shared_ptr<Tab> &tab, const wchar_t *method,
           const std::wstring &params,
           std::function<void(HRESULT, const std::wstring &)> done) {
    if (!tab->view || tab->closed)
      return false;
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    auto *cb =
        new Handler<ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
                    HRESULT, LPCWSTR>(
            IID_ICoreWebView2CallDevToolsProtocolMethodCompletedHandler,
            [weak, wt, done](HRESULT hr, LPCWSTR result) {
              auto s = weak.lock();
              auto t = wt.lock();
              if (s && s->alive && t && !t->closed) {
                if (FAILED(hr))
                  s->Error(L"Fallo del protocolo de aislamiento", hr);
                if (result && wcsnlen_s(result, 8u * 1024u * 1024u + 1) >
                                  8u * 1024u * 1024u)
                  done(E_INVALIDARG, L"");
                else
                  done(hr, result ? result : L"");
              }
              return S_OK;
            });
    const HRESULT hr =
        tab->view->CallDevToolsProtocolMethod(method, params.c_str(), cb);
    cb->Release();
    if (FAILED(hr)) {
      Error(L"No se pudo enviar el protocolo de aislamiento", hr);
      done(hr, L"");
      return false;
    }
    return true;
  }
  // `where` is the caller's source line: the only diagnostic that says WHICH
  // fail-closed check fired (no destination, header or page text is logged).
  void Disable(const std::shared_ptr<Tab> &tab, int where = __builtin_LINE()) {
    std::fprintf(stderr, "[BrowserPanel] Disable desde la linea %d\n", where);
    FinishAllAgent("host_unavailable", tab->id);
    tab->ready = false;
    tab->closed = true; // late protocol callbacks must not touch this tab
    tab->hasError = true;
    tab->error = L"Navegador bloqueado: no se pudo aplicar la política de red";
    if (tab->controller)
      Check(tab->controller->Close(), L"Cerrar pestaña insegura");
    Error(L"Navegador bloqueado: no se pudo aplicar la política de red");
    Refresh();
  }
  void Paused(const std::shared_ptr<Tab> &tab, const std::wstring &json) {
    const auto raw = preview::Narrow(json);
    preview::Value v;
    // Runtime-generated event: room for many headers, same size and depth.
    const bool parsed =
        preview::Parser(raw, true, true, preview::MessageLimit, 4, 256, 512)
            .Parse(v);
    if (!parsed || !preview::Text(v, "requestId", 1024) ||
        !preview::Text(v, "resourceType", 64) || !v.object.count("request") ||
        !preview::Text(v.object.at("request"), "url", 8192)) {
      std::fprintf(stderr,
                   "[BrowserPanel] requestPaused rechazado: parsed=%d "
                   "bytes=%zu utf16=%zu id=%d type=%d request=%d\n",
                   parsed ? 1 : 0, raw.size(), json.size(),
                   parsed && preview::Text(v, "requestId", 1024) ? 1 : 0,
                   parsed && preview::Text(v, "resourceType", 64) ? 1 : 0,
                   parsed && v.object.count("request") ? 1 : 0);
      Disable(tab);
      return;
    }
    const auto id = Quote(preview::Wide(v.object.at("requestId").string));
    const auto url =
        preview::Wide(v.object.at("request").object.at("url").string);
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    auto checked = [weak, wt](HRESULT hr, const std::wstring &) {
      if (auto s = weak.lock())
        if (auto t = wt.lock())
          if (FAILED(hr))
            s->Disable(t);
    };
    if (!Allowed(url)) {
      Cdp(tab, L"Fetch.failRequest",
          L"{\"requestId\":" + id + L",\"errorReason\":\"BlockedByClient\"}",
          checked);
      return;
    }
    if (!v.object.count("responseStatusCode")) {
      if (Fixture(url)) {
        // Native WebResourceRequested supplies the response; it also retains
        // the runtime's parsed policy headers, unlike a CDP synthetic body.
        Cdp(tab, L"Fetch.continueRequest", L"{\"requestId\":" + id + L"}",
            checked);
        return;
      }
      // Request-phase interception precedes each redirect and any network I/O.
      Cdp(tab, L"Fetch.continueRequest", L"{\"requestId\":" + id + L"}",
          checked);
      return;
    }
    if (!preview::Number(v, "responseStatusCode", 100, 599) ||
        !v.object.count("responseHeaders") ||
        v.object.at("responseHeaders").type != preview::Value::Array) {
      Disable(tab);
      return;
    }
    std::wstring headers = L"[";
    bool first = true;
    for (const auto &h : v.object.at("responseHeaders").array) {
      if (!preview::Text(h, "name", 1024) ||
          !preview::Text(h, "value", 32768, true)) {
        Disable(tab);
        return;
      }
      const auto &name = h.object.at("name").string;
      std::string lower = name;
      std::transform(
          lower.begin(), lower.end(), lower.begin(),
          [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
      const bool document = v.object.at("resourceType").string == "Document";
      if (lower == "connection-allowlist" ||
          (document &&
           (lower == "content-length" || lower == "content-encoding" ||
            lower == "transfer-encoding")))
        continue; // page cannot replace host policy.
      if (!first)
        headers += L",";
      first = false;
      auto headerValue = h.object.at("value").string;
      if (document && lower == "content-type" &&
          headerValue.rfind("text/", 0) == 0)
        headerValue =
            headerValue.substr(0, headerValue.find(';')) + "; charset=utf-8";
      headers += L"{\"name\":" + Quote(preview::Wide(name)) + L",\"value\":" +
                 Quote(preview::Wide(headerValue)) + L"}";
    }
    if (!first)
      headers += L",";
    headers += L"{\"name\":\"Connection-Allowlist\",\"value\":" +
               Quote(Allowlist()) + L"},";
    // Block workers, fenced frames, active plugin content and all WebSockets.
    // This is an additional CSP; the site's own policy remains in force.
    headers += L"{\"name\":\"Content-Security-Policy\",\"value\":\"worker-src "
               L"'none'; object-src 'none'; frame-src http: https:; "
               L"connect-src http: https:;\"}]";
    const auto params = L"{\"requestId\":" + id + L",\"responseCode\":" +
                        std::to_wstring(static_cast<int>(
                            v.object.at("responseStatusCode").number)) +
                        L",\"responseHeaders\":" + headers + L"}";
    if (v.object.at("resourceType").string == "Document") {
      const int status =
          static_cast<int>(v.object.at("responseStatusCode").number);
      if (status >= 300 && status < 400) {
        Cdp(tab, L"Fetch.fulfillRequest",
            params.substr(0, params.size() - 1) + L",\"body\":\"\"}", checked);
        return;
      }
      // continueResponse changes raw headers without rebuilding the runtime's
      // parsed security policy. Reconstruct documents before any script runs.
      Cdp(tab, L"Fetch.getResponseBody", L"{\"requestId\":" + id + L"}",
          [weak, wt, params, checked](HRESULT hr, const std::wstring &result) {
            auto s = weak.lock();
            auto t = wt.lock();
            if (!s || !t)
              return;
            const auto raw = preview::Narrow(result, 8u * 1024u * 1024u);
            preview::Value body;
            if (FAILED(hr) ||
                !preview::Parser(raw, true, true, 8u * 1024u * 1024u)
                     .Parse(body) ||
                !body.object.count("body") ||
                body.object.at("body").type != preview::Value::String ||
                !body.object.count("base64Encoded") ||
                body.object.at("base64Encoded").type !=
                    preview::Value::Boolean) {
              s->Disable(t);
              return;
            }
            std::string encoded = body.object.at("body").string;
            if (body.object.at("base64Encoded").number == 0) {
              if (encoded.size() > preview::CaptureLimit) {
                s->Disable(t);
                return;
              }
              encoded = preview::Base64(
                  reinterpret_cast<const unsigned char *>(encoded.data()),
                  encoded.size());
            }
            if (encoded.size() > 7u * 1024u * 1024u) {
              s->Disable(t);
              return;
            }
            s->Cdp(t, L"Fetch.fulfillRequest",
                   params.substr(0, params.size() - 1) + L",\"body\":" +
                       Quote(std::wstring(encoded.begin(), encoded.end())) +
                       L"}",
                   checked);
          });
      return;
    }
    Cdp(tab, L"Fetch.continueResponse", params, checked);
  }
  bool Configure(const std::shared_ptr<Tab> &tab) {
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    HRESULT resourceHr = tab->view->AddWebResourceRequestedFilter(
        L"https://preview.local/*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    if (SUCCEEDED(resourceHr))
      resourceHr = tab->view->AddWebResourceRequestedFilter(
          L"https://browser-guard.local/*",
          COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL);
    if (FAILED(resourceHr))
      return false;
    resourceHr = Subscribe<ICoreWebView2WebResourceRequestedEventHandler,
                           ICoreWebView2 *,
                           ICoreWebView2WebResourceRequestedEventArgs *>(
        &ICoreWebView2::add_WebResourceRequested, tab->view,
        IID_ICoreWebView2WebResourceRequestedEventHandler,
        [weak, wt](ICoreWebView2 *,
                   ICoreWebView2WebResourceRequestedEventArgs *args) {
          auto s = weak.lock();
          auto t = wt.lock();
          if (!s || !s->alive || !t || t->closed)
            return E_ABORT;
          ICoreWebView2WebResourceRequest *request = nullptr;
          LPWSTR url = nullptr, method = nullptr;
          HRESULT hr = args->get_Request(&request);
          if (SUCCEEDED(hr))
            hr = request->get_Uri(&url);
          if (SUCCEEDED(hr))
            hr = request->get_Method(&method);
          std::vector<unsigned char> bytes;
          const bool guard = url && std::wstring(url) == GuardUrl;
          if (guard) {
            const std::string body =
                "<!doctype html><title>Comprobando navegador</title>";
            bytes.assign(body.begin(), body.end());
          }
          const bool allowed =
              SUCCEEDED(hr) && url && method &&
              (wcscmp(method, L"GET") == 0 || wcscmp(method, L"HEAD") == 0) &&
              (guard || (s->Fixture(url) &&
                         preview::ReadResource(s->fixtureRoot, url, bytes)));
          std::wstring headers =
              L"Content-Type: " +
              std::wstring(guard     ? L"text/html; charset=utf-8"
                           : allowed ? preview::ResourceType(url)
                                     : L"text/plain") +
              L"\r\nConnection-Allowlist: " + s->Allowlist() +
              L"\r\nContent-Security-Policy: worker-src 'none'; object-src "
              L"'none'; frame-src http: https:; connect-src http: "
              L"https:;\r\nCache-Control: no-store\r\nX-Content-Type-Options: "
              L"nosniff\r\n";
          IStream *body = nullptr;
          hr = CreateStreamOnHGlobal(nullptr, TRUE, &body);
          if (SUCCEEDED(hr) && allowed && wcscmp(method, L"HEAD") != 0 &&
              !bytes.empty()) {
            ULONG written = 0;
            hr = body->Write(bytes.data(), static_cast<ULONG>(bytes.size()),
                             &written);
            if (SUCCEEDED(hr) && written != bytes.size())
              hr = STG_E_WRITEFAULT;
          }
          if (SUCCEEDED(hr)) {
            LARGE_INTEGER zero{};
            hr = body->Seek(zero, STREAM_SEEK_SET, nullptr);
          }
          ICoreWebView2WebResourceResponse *response = nullptr;
          if (SUCCEEDED(hr))
            hr = s->env->CreateWebResourceResponse(body, allowed ? 200 : 403,
                                                   allowed ? L"OK" : L"Blocked",
                                                   headers.c_str(), &response);
          if (SUCCEEDED(hr))
            hr = args->put_Response(response);
          if (response)
            response->Release();
          if (body)
            body->Release();
          if (url)
            CoTaskMemFree(url);
          if (method)
            CoTaskMemFree(method);
          if (request)
            request->Release();
          if (FAILED(hr))
            s->Disable(t);
          return hr;
        });
    if (FAILED(resourceHr))
      return false;
    ICoreWebView2Settings *settings = nullptr;
    if (!Check(tab->view->get_Settings(&settings), L"Ajustes del navegador") ||
        !settings)
      return false;
    HRESULT hr = webview_policy::ApplyMainViewSettings(settings, false);
    if (SUCCEEDED(hr))
      hr = settings->put_IsWebMessageEnabled(FALSE);
    ICoreWebView2Settings4 *identity = nullptr;
    if (SUCCEEDED(hr))
      hr = settings->QueryInterface(IID_ICoreWebView2Settings4,
                                    reinterpret_cast<void **>(&identity));
    if (SUCCEEDED(hr))
      hr = identity->put_IsPasswordAutosaveEnabled(FALSE);
    if (SUCCEEDED(hr))
      hr = identity->put_IsGeneralAutofillEnabled(FALSE);
    if (identity)
      identity->Release();
    settings->Release();
    if (!Check(hr, L"Desactivar puente y autocompletado"))
      return false;
    hr = Subscribe<ICoreWebView2NavigationStartingEventHandler, ICoreWebView2 *,
                   ICoreWebView2NavigationStartingEventArgs *>(
        &ICoreWebView2::add_NavigationStarting, tab->view,
        IID_ICoreWebView2NavigationStartingEventHandler,
        [weak, wt](ICoreWebView2 *,
                   ICoreWebView2NavigationStartingEventArgs *a) {
          auto s = weak.lock();
          auto t = wt.lock();
          if (!s || !s->alive || !t || t->closed)
            return a->put_Cancel(TRUE);
          LPWSTR u = nullptr;
          const HRESULT hr = a->get_Uri(&u);
          const std::wstring url = SUCCEEDED(hr) && u ? u : L"";
          if (u)
            CoTaskMemFree(u);
          BOOL user = FALSE, redirected = FALSE;
          a->get_IsUserInitiated(&user);
          a->get_IsRedirected(&redirected);
          bool ok = false;
          if (!url.empty() && url == GuardUrl)
            ok = true;
          else if (!url.empty() && t->ready) {
            // A page-initiated or redirected destination is never approved by
            // the page: it is blocked here and asked of the trusted UI.
            // 12-nov: una navegación pedida por el agente se presenta como
            // tal en el diálogo (antes decía «un enlace en el que hiciste
            // clic»).
            const char *source = redirected             ? "redirect"
                                 : !t->agentNav.empty() ? "agent"
                                 : user                 ? "link"
                                                        : "page";
            ok =
                s->Admission(t, url, source, s->ResumeTab(t, url)) == Admit::Go;
          }
          if (ok && url != GuardUrl) {
            t->loading = true;
            t->hasError = false;
            t->blocked = false;
            t->netError.clear();
            t->agentWorld = 0;
            t->debugWorld = 0;
            s->Publish();
          }
          return a->put_Cancel(ok ? FALSE : TRUE);
        });
    if (FAILED(hr))
      return false;
    hr =
        Subscribe<ICoreWebView2NavigationCompletedEventHandler, ICoreWebView2 *,
                  ICoreWebView2NavigationCompletedEventArgs *>(
            &ICoreWebView2::add_NavigationCompleted, tab->view,
            IID_ICoreWebView2NavigationCompletedEventHandler,
            [weak, wt](ICoreWebView2 *view,
                       ICoreWebView2NavigationCompletedEventArgs *args) {
              auto s = weak.lock();
              auto t = wt.lock();
              if (!s || !s->alive || !t || t->closed)
                return S_OK;
              LPWSTR source = nullptr;
              HRESULT hr = view->get_Source(&source);
              const bool guard =
                  SUCCEEDED(hr) && source && std::wstring(source) == GuardUrl;
              if (source)
                CoTaskMemFree(source);
              if (!guard) {
                BOOL done = TRUE;
                COREWEBVIEW2_WEB_ERROR_STATUS code =
                    COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                args->get_IsSuccess(&done);
                args->get_WebErrorStatus(&code);
                t->loading = false;
                // A navigation the policy cancelled reports OperationCanceled;
                // the blocked card, not an error, explains it.
                if (!done &&
                    code != COREWEBVIEW2_WEB_ERROR_STATUS_OPERATION_CANCELED) {
                  t->hasError = true;
                  t->errorCode = static_cast<int>(code);
                  t->errorDetail = t->netError;
                  t->error =
                      NetFailure(preview::Narrow(t->netError), LoadError(code));
                }
                s->FinishAgentNavigation(t, done != FALSE);
                s->Refresh();
                return S_OK;
              }
              if (t->ready)
                return S_OK;
              BOOL success = FALSE;
              hr = args->get_IsSuccess(&success);
              if (FAILED(hr) || !success) {
                s->Disable(t);
                return S_OK;
              }
              const std::wstring expression =
                  L"new Promise(resolve=>{const p=new "
                  L"RTCPeerConnection();let "
                  L"offerFailed=false;p.createDataChannel('guard');p."
                  L"createOffer().then(o=>p.setLocalDescription(o)).catch(()=>"
                  L"offerFailed=true);setTimeout(()=>{const "
                  L"blocked=!offerFailed&&p.iceConnectionState==='failed';p."
                  L"close();resolve("
                  L"blocked)},200)})";
              s->Cdp(
                  t, L"Runtime.evaluate",
                  L"{\"expression\":" + Quote(expression) +
                      L",\"awaitPromise\":true,\"returnByValue\":true}",
                  [weak, wt](HRESULT hr, const std::wstring &result) {
                    auto s = weak.lock();
                    auto t = wt.lock();
                    if (!s || !s->alive || !t || t->closed)
                      return;
                    const auto raw = preview::Narrow(result);
                    preview::Value value;
                    const bool blocked =
                        preview::Parser(raw, true, true).Parse(value) &&
                        value.object.count("result") &&
                        value.object.at("result").object.count("value") &&
                        value.object.at("result").object.at("value").type ==
                            preview::Value::Boolean &&
                        value.object.at("result").object.at("value").number ==
                            1;
                    if (FAILED(hr) || !blocked) {
                      s->Disable(t);
                      return;
                    }
                    t->ready = true;
                    s->SetStatus(L"Perfil propio · destinos por aprobación",
                                 false);
                    s->Check(t->view->Navigate(t->pending.c_str()),
                             L"Abrir página");
                    s->Refresh();
                  });
              return S_OK;
            });
    if (FAILED(hr))
      return false;
    hr = Subscribe<ICoreWebView2NavigationStartingEventHandler, ICoreWebView2 *,
                   ICoreWebView2NavigationStartingEventArgs *>(
        &ICoreWebView2::add_FrameNavigationStarting, tab->view,
        IID_ICoreWebView2NavigationStartingEventHandler,
        [weak](ICoreWebView2 *, ICoreWebView2NavigationStartingEventArgs *a) {
          auto s = weak.lock();
          LPWSTR u = nullptr;
          const HRESULT hr = a->get_Uri(&u);
          const bool ok = s && s->alive && SUCCEEDED(hr) && u && s->Allowed(u);
          if (u)
            CoTaskMemFree(u);
          return a->put_Cancel(ok ? FALSE : TRUE);
        });
    if (FAILED(hr))
      return false;
    hr = Subscribe<ICoreWebView2NewWindowRequestedEventHandler, ICoreWebView2 *,
                   ICoreWebView2NewWindowRequestedEventArgs *>(
        &ICoreWebView2::add_NewWindowRequested, tab->view,
        IID_ICoreWebView2NewWindowRequestedEventHandler,
        [weak, wt](ICoreWebView2 *,
                   ICoreWebView2NewWindowRequestedEventArgs *a) {
          const HRESULT handled = a->put_Handled(TRUE);
          auto s = weak.lock();
          auto opener = wt.lock();
          BOOL user = FALSE;
          LPWSTR u = nullptr;
          if (SUCCEEDED(handled) && s && s->alive && opener &&
              !opener->closed && SUCCEEDED(a->get_IsUserInitiated(&user)) &&
              user && SUCCEEDED(a->get_Uri(&u)) && u) {
            const std::wstring url = u;
            // The pop-up belongs to the tab that opened it: if that tab is
            // gone when the origin is approved, no tab is created.
            const unsigned openerId = opener->id;
            auto resume = [weak, url, openerId] {
              if (auto s = weak.lock())
                if (s->alive && s->Find(openerId))
                  s->NewTab(url);
            };
            if (s->Admission(nullptr, url, "popup", resume, openerId) ==
                Admit::Go)
              s->NewTab(url);
          }
          if (u)
            CoTaskMemFree(u);
          return handled;
        });
    if (FAILED(hr))
      return false;
    hr =
        Subscribe<ICoreWebView2PermissionRequestedEventHandler, ICoreWebView2 *,
                  ICoreWebView2PermissionRequestedEventArgs *>(
            &ICoreWebView2::add_PermissionRequested, tab->view,
            IID_ICoreWebView2PermissionRequestedEventHandler,
            [](ICoreWebView2 *, ICoreWebView2PermissionRequestedEventArgs *a) {
              return webview_policy::DenyPermission(a);
            });
    if (FAILED(hr))
      return false;
    hr = Subscribe<ICoreWebView2SourceChangedEventHandler, ICoreWebView2 *,
                   ICoreWebView2SourceChangedEventArgs *>(
        &ICoreWebView2::add_SourceChanged, tab->view,
        IID_ICoreWebView2SourceChangedEventHandler,
        [weak](ICoreWebView2 *, ICoreWebView2SourceChangedEventArgs *) {
          if (auto s = weak.lock())
            if (s->alive)
              s->Refresh();
          return S_OK;
        });
    if (FAILED(hr))
      return false;
    hr = Subscribe<ICoreWebView2DocumentTitleChangedEventHandler,
                   ICoreWebView2 *, IUnknown *>(
        &ICoreWebView2::add_DocumentTitleChanged, tab->view,
        IID_ICoreWebView2DocumentTitleChangedEventHandler,
        [weak, wt](ICoreWebView2 *v, IUnknown *) {
          auto s = weak.lock();
          auto t = wt.lock();
          LPWSTR title = nullptr;
          if (s && s->alive && t && SUCCEEDED(v->get_DocumentTitle(&title)) &&
              title) {
            t->title = std::wstring(title).substr(0, 120);
            CoTaskMemFree(title);
            s->Refresh();
          }
          return S_OK;
        });
    if (FAILED(hr))
      return false;
    hr = Subscribe<ICoreWebView2ProcessFailedEventHandler, ICoreWebView2 *,
                   ICoreWebView2ProcessFailedEventArgs *>(
        &ICoreWebView2::add_ProcessFailed, tab->view,
        IID_ICoreWebView2ProcessFailedEventHandler,
        [weak, wt](ICoreWebView2 *, ICoreWebView2ProcessFailedEventArgs *) {
          auto s = weak.lock();
          auto t = wt.lock();
          if (s && s->alive && t && !t->closed) {
            s->FinishAllAgent("host_unavailable");
            s->controlState = "session_closed";
            t->ready = false;
            t->hasError = true;
            t->error = L"El proceso del navegador dejó de responder.";
            if (s->controlSink)
              s->controlSink("renderer_failed", t->agentId);
            s->Refresh();
          }
          return S_OK;
        });
    if (FAILED(hr))
      return false;
    ICoreWebView2_4 *view4 = nullptr;
    if (FAILED(tab->view->QueryInterface(IID_ICoreWebView2_4,
                                         reinterpret_cast<void **>(&view4))))
      return false;
    auto *download =
        new Handler<ICoreWebView2DownloadStartingEventHandler, ICoreWebView2 *,
                    ICoreWebView2DownloadStartingEventArgs *>(
            IID_ICoreWebView2DownloadStartingEventHandler,
            [](ICoreWebView2 *, ICoreWebView2DownloadStartingEventArgs *a) {
              return webview_policy::CancelDownload(a);
            });
    EventRegistrationToken token{};
    hr = view4->add_DownloadStarting(download, &token);
    download->Release();
    view4->Release();
    if (FAILED(hr))
      return false;
    ICoreWebView2_10 *view10 = nullptr;
    if (FAILED(tab->view->QueryInterface(IID_ICoreWebView2_10,
                                         reinterpret_cast<void **>(&view10))))
      return false;
    auto *auth =
        new Handler<ICoreWebView2BasicAuthenticationRequestedEventHandler,
                    ICoreWebView2 *,
                    ICoreWebView2BasicAuthenticationRequestedEventArgs *>(
            IID_ICoreWebView2BasicAuthenticationRequestedEventHandler,
            [](ICoreWebView2 *,
               ICoreWebView2BasicAuthenticationRequestedEventArgs *a) {
              return a->put_Cancel(TRUE);
            });
    hr = view10->add_BasicAuthenticationRequested(auth, &token);
    auth->Release();
    view10->Release();
    if (FAILED(hr))
      return false;
    ICoreWebView2DevToolsProtocolEventReceiver *receiver = nullptr;
    if (FAILED(tab->view->GetDevToolsProtocolEventReceiver(
            L"Fetch.requestPaused", &receiver)))
      return false;
    auto *paused =
        new Handler<ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
                    ICoreWebView2 *,
                    ICoreWebView2DevToolsProtocolEventReceivedEventArgs *>(
            IID_ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
            [weak, wt](ICoreWebView2 *,
                       ICoreWebView2DevToolsProtocolEventReceivedEventArgs *a) {
              auto s = weak.lock();
              auto t = wt.lock();
              LPWSTR json = nullptr;
              const HRESULT hr = a->get_ParameterObjectAsJson(&json);
              if (s && s->alive && t && !t->closed) {
                if (SUCCEEDED(hr) && json)
                  s->Paused(t, json);
                else
                  s->Disable(t);
              }
              if (json)
                CoTaskMemFree(json);
              return S_OK;
            });
    hr = receiver->add_DevToolsProtocolEventReceived(paused, &token);
    paused->Release();
    receiver->Release();
    if (FAILED(hr))
      return false;
    ICoreWebView2DevToolsProtocolEventReceiver *failures = nullptr;
    if (FAILED(tab->view->GetDevToolsProtocolEventReceiver(
            L"Network.loadingFailed", &failures)))
      return false;
    auto *failed =
        new Handler<ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
                    ICoreWebView2 *,
                    ICoreWebView2DevToolsProtocolEventReceivedEventArgs *>(
            IID_ICoreWebView2DevToolsProtocolEventReceivedEventHandler,
            [wt](ICoreWebView2 *,
                 ICoreWebView2DevToolsProtocolEventReceivedEventArgs *a) {
              auto t = wt.lock();
              LPWSTR json = nullptr;
              if (t && !t->closed &&
                  SUCCEEDED(a->get_ParameterObjectAsJson(&json)) && json) {
                const auto raw = preview::Narrow(json);
                preview::Value v;
                // Only the main document's failure explains a failed load.
                if (preview::Parser(raw, true, true).Parse(v) &&
                    preview::Text(v, "type", 32) &&
                    v.object.at("type").string == "Document" &&
                    preview::Text(v, "errorText", 160))
                  t->netError = preview::Wide(v.object.at("errorText").string);
              }
              if (json)
                CoTaskMemFree(json);
              return S_OK;
            });
    hr = failures->add_DevToolsProtocolEventReceived(failed, &token);
    failed->Release();
    failures->Release();
    if (FAILED(hr))
      return false;
    // T6: registros acotados de consola y de red para browser_console y
    // browser_network. Solo metadatos (nivel y texto; método, dirección
    // redactada, estado, tipo y fallo): ni cuerpos ni cabeceras.
    for (const wchar_t *event :
         {L"Runtime.consoleAPICalled", L"Runtime.exceptionThrown",
          L"Network.requestWillBeSent", L"Network.responseReceived",
          L"Network.loadingFailed"})
      if (!ListenAgentLog(tab, event))
        return false;
    Cdp(tab, L"Runtime.enable", L"{}", [wt](HRESULT hr, const std::wstring &) {
      if (auto t = wt.lock())
        t->consoleReady = SUCCEEDED(hr);
    });
    Cdp(tab, L"Network.enable", L"{}",
        [weak, wt](HRESULT hr, const std::wstring &) {
          auto s = weak.lock();
          auto t = wt.lock();
          if (!s || !t)
            return;
          if (FAILED(hr)) {
            s->Disable(t);
            return;
          }
          s->Cdp(t, L"Network.setBlockedURLs",
                 L"{\"urls\":[\"ws://*\",\"wss://*\"]}",
                 [weak, wt](HRESULT hr, const std::wstring &) {
                   auto s = weak.lock();
                   auto t = wt.lock();
                   if (!s || !t)
                     return;
                   if (FAILED(hr)) {
                     s->Disable(t);
                     return;
                   }
                   s->Cdp(t, L"Fetch.enable",
                          L"{\"patterns\":[{\"urlPattern\":\"*\","
                          L"\"requestStage\":\"Request\"},{\"urlPattern\":\"*"
                          L"\",\"requestStage\":\"Response\"}]}",
                          [weak, wt](HRESULT hr, const std::wstring &) {
                            auto s = weak.lock();
                            auto t = wt.lock();
                            if (!s || !t)
                              return;
                            if (FAILED(hr)) {
                              s->Disable(t);
                              return;
                            }
                            s->Check(t->view->Navigate(GuardUrl),
                                     L"Comprobar aislamiento del navegador");
                          });
                 });
        });
    return true;
  }
  bool NewTab(const std::wstring &url = L"about:blank") {
    if (tabs.size() >= 12) {
      reason = "Máximo de 12 pestañas";
      Error(L"Máximo de 12 pestañas");
      return false;
    }
    auto tab = std::make_shared<Tab>();
    tab->id = nextTab++;
    tab->agentId = tabs.empty() && !initialTabId.empty()
                       ? initialTabId
                       : preview::Narrow(NewId());
    initialTabId.clear();
    if (tab->agentId.empty()) {
      reason = "No se pudo crear la identidad de pestaña";
      return false;
    }
    tab->pending = url;
    tabs.push_back(tab);
    active = tabs.size() - 1;
    Refresh();
    if (!env) {
      SetStatus(L"Inicializando navegador", false);
      return true;
    }
    CreateTab(tab);
    return true;
  }
  void CreateTab(const std::shared_ptr<Tab> &tab) {
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    auto *cb =
        new Handler<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
                    HRESULT, ICoreWebView2Controller *>(
            IID_ICoreWebView2CreateCoreWebView2ControllerCompletedHandler,
            [weak, wt](HRESULT hr, ICoreWebView2Controller *c) {
              auto s = weak.lock();
              auto t = wt.lock();
              if (!s || !s->alive || !t || t->closed) {
                if (c)
                  c->Close();
                return S_OK;
              }
              if (FAILED(hr) || !c) {
                s->Error(L"No se pudo crear la pestaña",
                         FAILED(hr) ? hr : E_FAIL);
                return S_OK;
              }
              c->AddRef();
              t->controller = c;
              hr = c->get_CoreWebView2(&t->view);
              if (FAILED(hr) || !t->view || !s->Configure(t)) {
                s->Disable(t);
                return S_OK;
              }
              s->Refresh();
              return S_OK;
            });
    const HRESULT hr = env->CreateCoreWebView2Controller(hwnd, cb);
    cb->Release();
    Check(hr, L"Crear pestaña");
  }
  void Initialize() {
    if (env || initializing)
      return;
    initializing = true;
    // Overrides can point at a personal profile or remove Chromium's sandbox.
    for (const auto name :
         {L"WEBVIEW2_USER_DATA_FOLDER", L"WEBVIEW2_BROWSER_EXECUTABLE_FOLDER",
          L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS"}) {
      if (GetEnvironmentVariableW(name, nullptr, 0)) {
        initializing = false;
        Error(L"Navegador bloqueado: hay overrides de entorno WebView2");
        return;
      }
    }
    auto weak = weak_from_this();
    auto *cb =
        new Handler<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
                    HRESULT, ICoreWebView2Environment *>(
            IID_ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler,
            [weak](HRESULT hr, ICoreWebView2Environment *e) {
              auto s = weak.lock();
              if (!s || !s->alive)
                return S_OK;
              s->initializing = false;
              if (FAILED(hr) || !e) {
                s->Error(L"No se pudo crear el perfil propio",
                         FAILED(hr) ? hr : E_FAIL);
                return S_OK;
              }
              LPWSTR version = nullptr;
              hr = e->get_BrowserVersionString(&version);
              const bool isolated =
                  SUCCEEDED(hr) && version &&
                  browser::Policy::RuntimeSupportsIsolation(version);
              if (version)
                CoTaskMemFree(version);
              if (!isolated) {
                s->Error(L"Navegador bloqueado: WebView2 requiere Chromium "
                         L"152+ para aislar WebRTC");
                return S_OK;
              }
              ICoreWebView2Environment7 *e7 = nullptr;
              LPWSTR actual = nullptr;
              hr = e->QueryInterface(IID_ICoreWebView2Environment7,
                                     reinterpret_cast<void **>(&e7));
              if (SUCCEEDED(hr))
                hr = e7->get_UserDataFolder(&actual);
              const auto expected =
                  preview::CanonicalRoot(s->dataRoot + L"\\profile");
              const auto resolved =
                  actual ? preview::CanonicalRoot(actual) : L"";
              if (actual)
                CoTaskMemFree(actual);
              if (e7)
                e7->Release();
              if (FAILED(hr) || expected.empty() || resolved.empty() ||
                  CompareStringOrdinal(expected.c_str(), -1, resolved.c_str(),
                                       -1, TRUE) != CSTR_EQUAL) {
                s->Error(L"Navegador bloqueado: el perfil real no coincide con "
                         L"el perfil propio");
                return S_OK;
              }
              e->AddRef();
              s->env = e;
              for (const auto &t : s->tabs)
                s->CreateTab(t);
              return S_OK;
            });
    std::wstring args = L"--enable-features=ConnectionAllowlists,"
                        L"OverrideConnectionAllowlistOriginTrial "
                        L"--disable-quic --disable-background-networking "
                        L"--disable-features=msEdgeSidebarV2";
#ifndef NDEBUG
    wchar_t port[8]{};
    const DWORD n =
        GetEnvironmentVariableW(L"BEATS_BROWSER_DEVTOOLS_PORT", port, 8);
    if (n > 0 && n < 8) {
      bool valid = true;
      unsigned p = 0;
      for (DWORD i = 0; i < n; ++i) {
        valid = valid && port[i] >= L'0' && port[i] <= L'9';
        p = p * 10 + static_cast<unsigned>(port[i] - L'0');
      }
      if (valid && p >= 1024 && p <= 65535)
        args +=
            L" --remote-debugging-address=127.0.0.1 --remote-debugging-port=" +
            std::wstring(port);
    }
#endif
    auto *options = new Options(args);
    const HRESULT hr = CreateCoreWebView2EnvironmentWithOptions(
        nullptr, (dataRoot + L"\\profile").c_str(), options, cb);
    options->Release();
    cb->Release();
    if (FAILED(hr)) {
      initializing = false;
      Error(L"Inicializar WebView2", hr);
    }
  }
  static constexpr UINT_PTR ApprovalTimer = 7;
  enum class Step { Back, Forward, Reload, Stop };
  std::function<void()> ResumeTab(const std::shared_ptr<Tab> &tab,
                                  const std::wstring &url) {
    auto weak = weak_from_this();
    std::weak_ptr<Tab> wt = tab;
    return [weak, wt, url] {
      auto s = weak.lock();
      auto t = wt.lock();
      if (s && s->alive && t && !t->closed)
        s->GoTab(t, url);
    };
  }
  bool DoNavigate(const std::wstring &typed) {
    reason.clear();
    const auto t = Active();
    if (!hwnd || !t) {
      reason = "No hay pestaña activa";
      return false;
    }
    if (typed.empty() || typed.size() > 8192) {
      reason = "Dirección vacía o demasiado larga";
      return false;
    }
    std::wstring url = typed;
    std::wstring mapped;
    const auto local = ProjectUrl(typed, mapped);
    if (local == LocalFile::Outside) {
      reason = "Solo se abren archivos web (HTML, CSS, JS, imágenes) de la "
               "carpeta del proyecto de la orden";
      return false;
    }
    if (local == LocalFile::Mapped)
      url = mapped;
    switch (Admission(t, url, "address", ResumeTab(t, url))) {
    case Admit::Go:
      GoTab(t, url);
      return true;
    case Admit::Asked:
      return true;
    default:
      return false;
    }
  }
  bool DoStep(Step step) {
    reason.clear();
    const auto t = Active();
    if (!t || !t->view || !t->ready || t->closed) {
      reason = "La pestaña aún no está lista";
      return false;
    }
    bool ok = true;
    t->blocked = false;
    if (step == Step::Back)
      ok = Check(t->view->GoBack(), L"Atrás");
    else if (step == Step::Forward)
      ok = Check(t->view->GoForward(), L"Adelante");
    else if (step == Step::Reload) {
      t->hasError = false;
      ok = Check(t->view->Reload(), L"Recargar");
    } else {
      ok = Check(t->view->Stop(), L"Detener");
      t->loading = false;
    }
    Refresh();
    return ok;
  }
  bool DoCloseTab(unsigned id) {
    reason.clear();
    for (size_t i = 0; i < tabs.size(); ++i) {
      if (tabs[i]->id != id)
        continue;
      FinishAllAgent("tab_not_found");
      if (!sessionId.empty()) {
        controlState = "user_control";
        ++controlEpoch;
      }
      if (controlSink)
        controlSink("tab_closed", tabs[i]->agentId);
      tabs[i]->closed = true;
      // A closed tab never resumes; a request left without waiters goes away.
      for (size_t k = approvals.size(); k-- > 0;) {
        auto &w = approvals[k].waiters;
        w.erase(std::remove_if(w.begin(), w.end(),
                               [id](const Waiter &x) { return x.tab == id; }),
                w.end());
        if (w.empty())
          approvals.erase(approvals.begin() + static_cast<std::ptrdiff_t>(k));
      }
      tabs.erase(tabs.begin() + static_cast<std::ptrdiff_t>(i));
      if (tabs.empty())
        return NewTab();
      if (i < active)
        --active;
      active = std::min(active, tabs.size() - 1);
      Refresh();
      return true;
    }
    reason = "Pestaña desconocida";
    return false;
  }
  // Cierre pedido por el agente: como DoCloseTab, pero sin pasar a «control
  // del usuario» (no es una acción humana).
  void AgentCloseTab(const std::shared_ptr<Tab> &tab) {
    const unsigned id = tab->id;
    FinishAllAgent("tab_not_found", id);
    tab->closed = true;
    for (size_t k = approvals.size(); k-- > 0;) {
      auto &w = approvals[k].waiters;
      w.erase(std::remove_if(w.begin(), w.end(),
                             [id](const Waiter &x) { return x.tab == id; }),
              w.end());
      if (w.empty())
        approvals.erase(approvals.begin() + static_cast<std::ptrdiff_t>(k));
    }
    for (size_t i = 0; i < tabs.size(); ++i)
      if (tabs[i]->id == id) {
        tabs.erase(tabs.begin() + static_cast<std::ptrdiff_t>(i));
        if (i < active)
          --active;
        break;
      }
    if (tabs.empty()) {
      NewTab();
      return;
    }
    active = std::min(active, tabs.size() - 1);
    Refresh();
  }
  bool DoSelectTab(unsigned id) {
    reason.clear();
    for (size_t i = 0; i < tabs.size(); ++i)
      if (tabs[i]->id == id) {
        active = i;
        Refresh();
        return true;
      }
    reason = "Pestaña desconocida";
    return false;
  }
  bool DoRegisterApp(const std::wstring &url) {
    reason.clear();
    const auto t = Active();
    if (!t || !policy.RegisterApp(url)) {
      reason = "La app requiere un origen localhost con puerto válido";
      Error(L"La app requiere un origen localhost con puerto válido");
      return false;
    }
    GoTab(t, url);
    return true;
  }
  bool DoResolve(const std::string &id, bool allow) {
    reason.clear();
    for (size_t i = 0; i < approvals.size(); ++i) {
      if (approvals[i].id != id)
        continue;
      Approval a = approvals[i];
      approvals.erase(approvals.begin() + static_cast<std::ptrdiff_t>(i));
      // La aprobación ya salió de la lista: la navegación del agente que
      // esperaba en cada pestaña termina aquí con permission_required.
      const auto refuse = [&](const wchar_t *why) {
        for (const auto &w : a.waiters)
          if (auto t = Find(w.tab)) {
            t->blockedReason = why;
            FinishAgentNavigation(t, false);
          }
      };
      if (!allow) {
        denied[a.origin] = GetTickCount64();
        refuse(L"Destino rechazado. No se abrirá hasta que lo apruebes.");
        Refresh();
        return true;
      }
      if (!policy.Approve(a.origin, ledger)) {
        reason = "No se pudo guardar la aprobación";
        Error(L"No se pudo guardar la aprobación; destino bloqueado");
        refuse(L"No se pudo guardar la aprobación; destino bloqueado.");
        Refresh();
        return false;
      }
      // The exact origin is approved and persisted: resume every waiter. La
      // carga de una navegación del agente empieza a contar ahora.
      for (const auto &w : a.waiters) {
        RearmAgentLoad(Find(w.tab));
        if (w.resume)
          w.resume();
      }
      Refresh();
      return true;
    }
    reason = "Solicitud de aprobación desconocida";
    return false;
  }
  static LRESULT CALLBACK Proc(HWND h, UINT m, WPARAM w, LPARAM l) {
    auto *s = reinterpret_cast<Impl *>(GetWindowLongPtrW(h, GWLP_USERDATA));
    if (m == WM_NCCREATE) {
      s = static_cast<Impl *>(
          reinterpret_cast<CREATESTRUCTW *>(l)->lpCreateParams);
      s->hwnd = h;
      SetWindowLongPtrW(h, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(s));
    }
    if (!s)
      return DefWindowProcW(h, m, w, l);
    if (m == WM_SIZE) {
      s->Layout();
      return 0;
    }
    if (m == WM_TIMER && w == ApprovalTimer) {
      s->FlushPhysicalControl();
      std::vector<std::string> expired;
      const auto now = GetTickCount64();
      for (const auto &entry : s->agentPending)
        if (now >= entry.second.deadline ||
            (entry.second.navTab && entry.second.loadDeadline &&
             now >= entry.second.loadDeadline &&
             !s->Awaiting(entry.second.navTab)))
          expired.push_back(entry.first);
      std::vector<unsigned> settled;
      for (const auto &entry : s->agentPending)
        if (entry.second.history && entry.second.navTab &&
            now - entry.second.started >= 1500)
          settled.push_back(entry.second.navTab);
      for (const unsigned tabId : settled)
        if (const auto t = s->Find(tabId))
          if (!t->loading && !t->blocked && !t->hasError &&
              !t->agentNav.empty())
            s->AgentNavOk(t);
      for (const auto &id : expired)
        if (s->agentPending.count(id))
          s->FinishAgent(id, "timeout");
      s->HookPageInput();
      s->Sweep();
      return 0;
    }
    if (m == PhysicalControlMessage) {
      s->FlushPhysicalControl();
      return 0;
    }
    if (m == WM_COMMAND) {
      s->HumanControl();
      // Native controls exist only in the full secondary window, which has no
      // trusted WebUI; the cabina panel never reaches this code.
      const int id = LOWORD(w);
      wchar_t url[8193]{};
      GetWindowTextW(GetDlgItem(h, Address), url, 8193);
      if (id == HideControl) {
        PostMessageW(s->parent, WM_CLOSE, 0, 0);
        return 0;
      }
      if (id == Add)
        s->NewTab();
      else if (id == Register)
        s->DoRegisterApp(url);
      else if (id == Remove && s->Active())
        s->DoCloseTab(s->Active()->id);
      else if (id == Tabs && HIWORD(w) == CBN_SELCHANGE) {
        const auto i = SendDlgItemMessageW(h, Tabs, CB_GETCURSEL, 0, 0);
        if (i >= 0 && static_cast<size_t>(i) < s->tabs.size())
          s->DoSelectTab(s->tabs[static_cast<size_t>(i)]->id);
      } else if (id == Go) {
        if (!s->DoNavigate(url))
          s->Error(L"Destino rechazado");
      } else if (id == IdBack)
        s->DoStep(Step::Back);
      else if (id == IdForward)
        s->DoStep(Step::Forward);
      else if (id == IdReload)
        s->DoStep(Step::Reload);
      return 0;
    }
    if (m == WM_NCDESTROY) {
      s->UnregisterPhysicalInput();
      s->FinishAllAgent("session_closed");
      s->controlState = "session_closed";
      s->open = false;
      s->hwnd = nullptr;
      SetWindowLongPtrW(h, GWLP_USERDATA, 0);
    }
    return DefWindowProcW(h, m, w, l);
  }
};

BrowserPanel::BrowserPanel() : m_impl(std::make_shared<Impl>()) {}
bool BrowserPanel::IsPhysicalPageInput(const PhysicalInput &input) noexcept {
  if (!input.targetInPage)
    return false;
  if (input.keyboard)
    return input.foregroundInHost &&
           !(input.flags & (LLKHF_INJECTED | LLKHF_LOWER_IL_INJECTED)) &&
           (input.message == WM_KEYDOWN || input.message == WM_SYSKEYDOWN);
  if (input.flags & (LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED))
    return false;
  // 12-nov: mover el ratón por encima de la página ya NO quita el control al
  // agente (al aprobar un origen, la página aparecía bajo el cursor y el
  // primer movimiento lo pausaba). Solo una entrada deliberada: clic, rueda
  // o tecla.
  switch (input.message) {
  case WM_LBUTTONDOWN:
  case WM_RBUTTONDOWN:
  case WM_MBUTTONDOWN:
  case WM_XBUTTONDOWN:
  case WM_MOUSEWHEEL:
  case WM_MOUSEHWHEEL:
    return true;
  default:
    return false;
  }
}
BrowserPanel::~BrowserPanel() {
  m_impl->UnregisterPhysicalInput();
  m_impl->FinishAllAgent("session_closed");
  m_impl->alive = false;
  if (m_impl->hwnd)
    DestroyWindow(m_impl->hwnd);
}
bool BrowserPanel::Open(HWND parent, const std::wstring &dataRoot,
                        bool fullWindow) {
  auto &s = *m_impl;
  if (s.hwnd) {
    if (!s.RegisterPhysicalInput())
      return false;
    s.open = true;
    RECT r{};
    GetClientRect(parent, &r);
    Resize(r.right, r.bottom);
    return true;
  }
  if (!IsWindow(parent) || dataRoot.empty())
    return false;
  s.parent = parent;
  s.full = fullWindow;
  s.dataRoot = dataRoot + L"\\browser";
  s.ledger = s.dataRoot + L"\\approved-origins.txt";
  if (!CreateDirectoryW(s.dataRoot.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS)
    return false;
  const DWORD attrs = GetFileAttributesW(s.dataRoot.c_str());
  if (attrs == INVALID_FILE_ATTRIBUTES ||
      (attrs & FILE_ATTRIBUTE_REPARSE_POINT))
    return false;
  const auto profileDir = s.dataRoot + L"\\profile";
  if (!CreateDirectoryW(profileDir.c_str(), nullptr) &&
      GetLastError() != ERROR_ALREADY_EXISTS)
    return false;
  if (preview::CanonicalRoot(profileDir).empty())
    return false;
  // Un ledger ilegible (DPAPI de otro usuario/equipo, entropy de otra versión
  // o datos migrados) no puede dejar el panel del navegador inservible para
  // siempre: Load ya vació las aprobaciones, así que se sigue con la política
  // vacía — el origen pedirá aprobación de nuevo, que es el lado seguro.
  s.policy.Load(s.ledger);
  WNDCLASSW wc{};
  wc.lpfnWndProc = Impl::Proc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = L"DevAgentsBrowserPanel";
  wc.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_WINDOW + 1);
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
    return false;
  s.hwnd =
      CreateWindowExW(0, wc.lpszClassName, L"Navegador DevAgents",
                      WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
                      0, 0, 500, 500, parent, nullptr, wc.hInstance, &s);
  if (!s.hwnd)
    return false;
  if (!s.RegisterPhysicalInput()) {
    DestroyWindow(s.hwnd);
    s.reason = "No se pudo instalar el control humano nativo";
    return false;
  }
  if (fullWindow) {
    const struct {
      int id;
      const wchar_t *kind, *text;
      DWORD style;
    } controls[] = {
        {Tabs, L"COMBOBOX", L"", CBS_DROPDOWNLIST | WS_VSCROLL | WS_TABSTOP},
        {Add, L"BUTTON", L"+", WS_TABSTOP},
        {Remove, L"BUTTON", L"−", WS_TABSTOP},
        {IdBack, L"BUTTON", L"<", WS_TABSTOP},
        {IdForward, L"BUTTON", L">", WS_TABSTOP},
        {IdReload, L"BUTTON", L"↻", WS_TABSTOP},
        {Address, L"EDIT", L"", ES_AUTOHSCROLL | WS_BORDER | WS_TABSTOP},
        {Go, L"BUTTON", L"Ir", WS_TABSTOP},
        {HideControl, L"BUTTON", L"×", WS_TABSTOP},
        {Status, L"STATIC", L"Inicializando navegador", SS_LEFT},
        {Register, L"BUTTON", L"App", WS_TABSTOP}};
    for (const auto &c : controls) {
      HWND child = CreateWindowExW(
          0, c.kind, c.text, WS_CHILD | WS_VISIBLE | c.style, 0, 0, 20, 20,
          s.hwnd, reinterpret_cast<HMENU>(static_cast<INT_PTR>(c.id)),
          wc.hInstance, nullptr);
      if (!child) {
        DestroyWindow(s.hwnd);
        return false;
      }
      SendMessageW(child, WM_SETFONT,
                   reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)),
                   TRUE);
    }
  }
  SetTimer(s.hwnd, Impl::ApprovalTimer, 1000, nullptr);
  s.open = true;
  RECT r{};
  GetClientRect(parent, &r);
  Resize(r.right, r.bottom);
  s.NewTab();
  s.Initialize();
  return true;
}
void BrowserPanel::Hide() {
  auto &s = *m_impl;
  s.physicalTakePending = false;
  s.UnregisterPhysicalInput();
  s.FinishAllAgent("session_closed");
  s.controlState = "session_closed";
  if (s.controlSink)
    s.controlSink("close", s.Active() ? s.Active()->agentId : "");
  s.DenyAll(L"El panel se cerró; destino rechazado.");
  s.covered = s.coverWanted = false;
  s.open = false;
  if (s.hwnd)
    ShowWindow(s.hwnd, SW_HIDE);
  s.Refresh();
}
void BrowserPanel::SetEventSink(EventSink sink) {
  m_impl->sink = std::move(sink);
}
void BrowserPanel::ExecuteAgent(const std::string &requestJson,
                                AgentCompletion done) {
  m_impl->ExecuteAgent(requestJson, std::move(done));
}
void BrowserPanel::CancelAgent(const std::string &requestId,
                               const std::string &code) {
  m_impl->FinishAgent(requestId, code);
}
void BrowserPanel::SetControlSink(ControlSink sink) {
  m_impl->controlSink = std::move(sink);
}
void BrowserPanel::HumanControl() { m_impl->HumanControl(); }
void BrowserPanel::SetAgentState(const std::string &state, uint64_t epoch) {
  auto &s = *m_impl;
  if (state != "agent_control" && state != "user_control" &&
      state != "session_closed")
    return;
  if (epoch < s.controlEpoch)
    return;
  if (state != "agent_control" || epoch != s.controlEpoch)
    s.FinishAllAgent(state == "user_control" ? "user_control"
                                             : "session_closed");
  s.controlState = state;
  s.controlEpoch = epoch;
  s.Publish();
}
void BrowserPanel::SetSessionIdentity(const std::string &sessionId,
                                      const std::string &tabId) {
  auto &s = *m_impl;
  const bool changed = s.sessionId != sessionId;
  const bool replaceTabs = changed && !s.sessionId.empty();
  if (changed) {
    s.physicalTakePending = false;
    s.FinishAllAgent("session_closed");
    s.controlState = "session_closed";
    s.controlEpoch = 0;
  }
  if (replaceTabs) {
    // A panel rebound to another order cannot adopt that order's old pages.
    // The first attach keeps a page the human loaded before opening transport.
    s.DenyAll(L"La sesión de navegador cambió; destino rechazado.");
    for (const auto &tab : s.tabs)
      tab->closed = true;
    s.tabs.clear();
    s.active = 0;
  }
  s.sessionId = sessionId;
  if (changed)
    s.initialTabId = tabId;
  if (changed && !tabId.empty() && s.Active()) {
    s.Active()->agentId = tabId;
    s.initialTabId.clear();
  }
  if (replaceTabs && s.hwnd)
    s.NewTab();
  s.Refresh();
}
bool BrowserPanel::Visible() const { return m_impl->hwnd && m_impl->open; }
void BrowserPanel::Resize(int width, int height) {
  auto &s = *m_impl;
  if (!s.hwnd)
    return;
  const UINT dpi = GetDpiForWindow(s.parent);
  const int top = s.full ? 0 : MulDiv(TitlebarCssHeight, dpi ? dpi : 96, 96);
  const int bar = s.full ? 0 : MulDiv(BarCssHeight, dpi ? dpi : 96, 96);
  const int w = s.full ? width : std::max(0, width / 2);
  SetWindowPos(s.hwnd, HWND_TOP, width - w, top + bar, w,
               std::max(0, height - top - bar), SWP_NOACTIVATE);
  s.Refresh();
}
bool BrowserPanel::SetFixtureRoot(const std::wstring &root) {
  std::string reason;
  auto r = preview::CanonicalRoot(root);
  if (r.empty() || !preview::SafeTree(r, reason)) {
    // Sin raíz verificada no se sirve NINGÚN archivo local (tampoco los de
    // una orden anterior): el navegador sigue valiendo para http(s).
    m_impl->fixtureRoot.clear();
    std::fprintf(stderr, "[BrowserPanel] carpeta de la orden no servible: %s\n",
                 reason.c_str());
    return false;
  }
  m_impl->fixtureRoot = r;
  return true;
}
std::string BrowserPanel::StateJson() const { return m_impl->State(); }
std::string BrowserPanel::Reason() const { return m_impl->reason; }
// 12-nov (orden del propietario): las acciones de la barra de la cabina ya NO
// dejan el navegador en «control del usuario» (el agente quedaba pausado hasta
// pulsar «Reanudar agente» por haber aprobado un sitio o escrito una
// dirección). Una navegación humana sí invalida lo que el agente tuviera a
// medias en ESA pestaña (`busy`, reintentable): no se le entrega como propia
// una página que no pidió. El control solo cambia con una entrada real dentro
// de la página o con el botón «Tomar control».
bool BrowserPanel::Navigate(const std::wstring &url) {
  m_impl->HumanStep();
  return m_impl->DoNavigate(url);
}
bool BrowserPanel::Back() {
  m_impl->HumanStep();
  return m_impl->DoStep(Impl::Step::Back);
}
bool BrowserPanel::Forward() {
  m_impl->HumanStep();
  return m_impl->DoStep(Impl::Step::Forward);
}
bool BrowserPanel::Reload() {
  m_impl->HumanStep();
  return m_impl->DoStep(Impl::Step::Reload);
}
bool BrowserPanel::Stop() {
  m_impl->HumanStep();
  return m_impl->DoStep(Impl::Step::Stop);
}
bool BrowserPanel::NewTab() {
  m_impl->reason.clear();
  return m_impl->hwnd && m_impl->NewTab();
}
bool BrowserPanel::CloseTab(unsigned id) { return m_impl->DoCloseTab(id); }
bool BrowserPanel::SelectTab(unsigned id) { return m_impl->DoSelectTab(id); }
bool BrowserPanel::RegisterApp(const std::wstring &url) {
  m_impl->HumanStep();
  return m_impl->DoRegisterApp(url);
}
bool BrowserPanel::SetCover(bool on) { return m_impl->DoCover(on); }
bool BrowserPanel::RetryBlocked() {
  auto &s = *m_impl;
  s.reason.clear();
  const auto t = s.Active();
  if (!t || !t->blocked || t->blockedUrl.empty()) {
    s.reason = "No hay ningún destino bloqueado en esta pestaña";
    return false;
  }
  // Mismo destino que pidió el agente o la página: se pregunta al usuario
  // como petición suya (source "address") sin tocar el control del agente.
  return s.DoNavigate(t->blockedUrl);
}
bool BrowserPanel::ResolveApproval(const std::string &id, bool allow) {
  return m_impl->DoResolve(id, allow);
}
void BrowserPanel::UiRestarted() {
  // La cabina nueva no tiene ninguna capa abierta ni la imagen de la anterior.
  m_impl->covered = m_impl->coverWanted = false;
  m_impl->DenyAll(L"La interfaz se reinició; destino rechazado.");
}
#ifndef NDEBUG
bool BrowserPanel::CheckIsolationSettings() const {
  if (!m_impl->env || m_impl->tabs.empty())
    return false;
  for (const auto &tab : m_impl->tabs) {
    if (!tab->view || !tab->ready)
      return false;
    ICoreWebView2Settings *settings = nullptr;
    BOOL messages = TRUE, objects = TRUE;
    HRESULT hr = tab->view->get_Settings(&settings);
    if (SUCCEEDED(hr) && settings)
      hr = settings->get_IsWebMessageEnabled(&messages);
    if (SUCCEEDED(hr) && settings)
      hr = settings->get_AreHostObjectsAllowed(&objects);
    if (settings)
      settings->Release();
    if (FAILED(hr) || messages || objects)
      return false;
  }
  return true;
}
#endif
} // namespace beats
