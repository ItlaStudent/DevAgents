#ifndef BEATS_WEBVIEW_HOST_HPP
#define BEATS_WEBVIEW_HOST_HPP

#include "WebView2.h"
#include <functional>
#include <memory>
#include <string>
#include <windows.h>

#include <chrono>

namespace beats {

class WebViewHost {
public:
  using MessageCallback = std::function<void(const std::wstring &message)>;
  static constexpr size_t BridgeMessageLimit = 28u * 1024u * 1024u;
  static bool MessageWithinBound(size_t length) {
    return length <= BridgeMessageLimit;
  }

  WebViewHost();
  ~WebViewHost();

  bool Initialize(HWND hWnd, const std::wstring &userDataDir,
                  const std::wstring &bundleDir, bool enableDevTools,
                  const std::wstring &extraCmdArgs = L"");

  // E5.21: sufijo de la URL de arranque (p.ej. L"?ventana=2&vista=editor").
  // Se fija antes de Initialize y se conserva para las recreaciones.
  void SetNavQuery(const std::wstring &q) { m_navQuery = q; }
  const std::wstring &GetNavQuery() const { return m_navQuery; }
  // E5.25: an isolated, untrusted page; receives no bridge callbacks/events.
  bool ConfigurePreview(const std::wstring &root, const std::string &path,
                        long orderId, int windowId, MessageCallback picked);
  bool IsPreview() const { return static_cast<bool>(m_preview); }
  HRESULT InitializePreview(ICoreWebView2 *view, bool devTools);

  void Resize(int width, int height);
  // QA 10-nov: la ventana se movio (otro monitor) sin cambiar de tamano.
  void NotifyMoved();
  bool GetBounds(RECT &bounds) const;
  bool PostMessageJson(const std::wstring &jsonMessage);
  void SetMessageCallback(MessageCallback callback) { m_onMessage = callback; }
  MessageCallback GetMessageCallback() const { return m_onMessage; }

  void SetStartTime(std::chrono::high_resolution_clock::time_point t) {
    m_startTime = t;
  }
  std::chrono::high_resolution_clock::time_point GetStartTime() const {
    return m_startTime;
  }

  HWND GetParentHwnd() const { return m_parentHwnd; }
  // Parametros de arranque conservados (los usa la recreacion y la cola del
  // entorno compartido de E5.21).
  const std::wstring &GetInitBundleDir() const { return m_initBundleDir; }
  bool GetInitDevTools() const { return m_initDevTools; }
  void SetController(ICoreWebView2Controller *ctrl) {
    if (m_controller)
      m_controller->Release();
    m_controller = ctrl;
    if (m_controller)
      m_controller->AddRef();
  }
  void SetWebView(ICoreWebView2 *view) {
    if (m_webView)
      m_webView->Release();
    m_webView = view;
    if (m_webView)
      m_webView->AddRef();
  }

  bool IsInitialized() const { return m_webView != nullptr; }
  void DumpDomToCdpFile();

  // recuperación acotada de muertes del renderer. Sin handler de
  // ProcessFailed, un crash del proceso de render dejaba la ventana en
  // blanco puro hasta reiniciar la app. La cota evita un bucle
  // crash→reload→crash si la causa es persistente.
  bool NoteCrashForReload();
  void NoteNavigationSucceeded() {
    m_crashReloads = 0;
    m_recoveryAttempts = 0;
  }
  // 22-09 — salir de la pantalla blanca en vez de rendirse: recarga diferida
  // con espera creciente, o recreacion completa si murio el navegador.
  void ScheduleRecovery(bool recreate);
  void RunRecovery();

private:
  struct PreviewState;
  std::shared_ptr<PreviewState> m_preview;
  HWND m_parentHwnd = nullptr;
  MessageCallback m_onMessage;
  ICoreWebView2Controller *m_controller = nullptr;
  ICoreWebView2 *m_webView = nullptr;
  std::chrono::high_resolution_clock::time_point m_startTime;
  int m_crashReloads = 0;
  int m_recoveryAttempts = 0;
  bool m_recoveryRecreate = false;
  std::wstring m_initUserDataDir;
  std::wstring m_initBundleDir;
  bool m_initDevTools = false;
  std::wstring m_initExtraArgs;
  std::wstring m_navQuery;
  std::chrono::steady_clock::time_point m_firstCrash{};
};

} // namespace beats

#endif // BEATS_WEBVIEW_HOST_HPP
